import dataclasses
import json
import os
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from harness.builders import make_spec_darwin, make_spec_linux
from launcher.lib.build_spec import (
    CredentialHostSpec,
    InjectedCredentialSpec,
    ProxySpec,
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
)
from launcher.lib.constants import (
    CA_CERT,
    JAVA_CACERTS,
    LAUNCH_PID,
    SESSION_RETENTION,
)
from launcher.lib.session_state import (
    _prune_sessions_root,
    _start_proxy,
    create_java_truststore,
    create_proxy_state,
    kill_proxy,
)

SESSION_COUNT = SESSION_RETENTION + 5


def _session(root: Path, index: int) -> Path:
    return root / f"20200101-{index:06d}-1234-sandboxed-bash"


def _populate(root: Path) -> None:
    for index in range(1, SESSION_COUNT + 1):
        _session(root, index).mkdir(parents=True)


def _dead_pid() -> int:
    process = subprocess.Popen(["true"])
    process.wait()
    return process.pid


def test_the_oldest_sessions_beyond_the_limit_are_removed(tmp_path: Path) -> None:
    _populate(tmp_path)

    _prune_sessions_root(tmp_path)

    remaining = sorted(path.name for path in tmp_path.iterdir())
    expected = sorted(_session(tmp_path, index).name for index in range(6, SESSION_COUNT + 1))
    assert remaining == expected


def test_a_running_session_survives_however_old(tmp_path: Path) -> None:
    _populate(tmp_path)
    (_session(tmp_path, 1) / LAUNCH_PID).write_text(str(os.getpid()))

    _prune_sessions_root(tmp_path)

    assert _session(tmp_path, 1).is_dir()


def test_a_session_with_a_dead_pid_is_removed(tmp_path: Path) -> None:
    _populate(tmp_path)
    (_session(tmp_path, 2) / LAUNCH_PID).write_text(str(_dead_pid()))

    _prune_sessions_root(tmp_path)

    assert not _session(tmp_path, 2).exists()


def test_the_proxy_gets_only_the_redirect_variable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    envs: list[dict[str, str]] = []

    def record(argv: list[str], **kwargs: Any) -> None:
        envs.append(kwargs["env"])

    monkeypatch.setattr(subprocess, "Popen", record)
    monkeypatch.setenv("HOST_SECRET", "secret")
    proxy = ProxySpec(
        binary=Path("/nix/store/proxy/bin/sandbox-proxy"),
        allowlist_file=Path("/nix/store/allowlist.json"),
        redirects={"httpbin.test": "127.0.0.1:1"},
    )

    _start_proxy(proxy, tmp_path)

    assert envs == [{"SANDBOX_PROXY_REDIRECT": "httpbin.test=127.0.0.1:1"}]


def test_the_proxy_receives_the_credentials_on_stdin(tmp_path: Path) -> None:
    binary = tmp_path / "sandbox-proxy"
    binary.write_text('#!/bin/sh\nIFS= read -r line\nprintf %s "$line" > "$2.stdin"\necho 1234\n')
    binary.chmod(0o755)
    proxy = ProxySpec(binary=binary, allowlist_file=tmp_path / "allowlist.json", redirects={})
    injected = {
        "GH_TOKEN": InjectedCredentialSpec(
            placeholder="dummy",
            hosts={"api.github.com": CredentialHostSpec(scheme="bearer", username=None, header=None)},
        ),
    }
    spec = dataclasses.replace(make_spec_linux(), proxy=proxy, injected_credentials=injected)

    state = create_proxy_state(spec, tmp_path, {"GH_TOKEN": "real"})
    kill_proxy(state)

    assert state is not None and state.port == 1234
    received = json.loads((tmp_path / f"{CA_CERT}.stdin").read_text())
    assert received == {"api.github.com": {"header": "Authorization", "value": "Bearer real"}}


def test_no_java_truststore_without_a_proxy(tmp_path: Path) -> None:
    assert create_java_truststore(make_spec_linux(), tmp_path, tmp_path) is None


def test_a_proxy_without_openssl_is_refused(tmp_path: Path) -> None:
    spec = dataclasses.replace(
        make_spec_linux(openssl=None),
        proxy=ProxySpec(
            binary=Path("/nix/store/proxy/bin/sandbox-proxy"),
            allowlist_file=Path("/nix/store/allowlist.json"),
            redirects={},
        ),
    )

    with pytest.raises(SystemExit, match="OpenSSL"):
        create_java_truststore(spec, tmp_path, tmp_path)


@pytest.mark.parametrize("make_spec", [make_spec_linux, make_spec_darwin])
def test_the_java_truststore_gets_the_host_cas_and_the_proxy_ca(
    make_spec: Callable[..., SandboxBuildSpecLinux | SandboxBuildSpecDarwin],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    fake_openssl = tmp_path / "openssl"
    fake_openssl.write_text(
        "#!/bin/sh\n"
        'printf \'%s\\n\' "$@" > "$ARGV_FILE"\n'
        "out=\n"
        'while [ "$#" -gt 0 ]; do\n'
        '  if [ "$1" = "-out" ]; then out=$2; shift 2; else shift; fi\n'
        "done\n"
        'printf fake > "$out"\n'
    )
    fake_openssl.chmod(0o755)
    argv_file = tmp_path / "argv"
    monkeypatch.setenv("ARGV_FILE", str(argv_file))

    bundle = tmp_path / "ca-no-trust-rules-bundle.crt"
    bundle.write_text("-----BEGIN CERTIFICATE-----\nhost\n-----END CERTIFICATE-----\n")
    session_dir = tmp_path / "session"
    session_dir.mkdir()
    (session_dir / CA_CERT).write_text(
        "-----BEGIN CERTIFICATE-----\nproxy\n-----END CERTIFICATE-----\n"
    )

    destination = session_dir / "tmp"
    destination.mkdir()

    spec = dataclasses.replace(
        make_spec(openssl=fake_openssl),
        proxy=ProxySpec(
            binary=Path("/nix/store/proxy/bin/sandbox-proxy"),
            allowlist_file=Path("/nix/store/allowlist.json"),
            redirects={},
        ),
        cacert_no_trust_rules_bundle=bundle,
    )

    output = create_java_truststore(spec, session_dir, destination)

    assert output is not None
    assert output == destination / JAVA_CACERTS
    assert output.read_bytes() == b"fake"

    args = argv_file.read_text().splitlines()
    assert args[:4] == ["pkcs12", "-in", str(bundle), "-certfile"]
    assert "-export" in args
    assert "-nokeys" in args
    assert args[args.index("-certfile") + 1] == str(session_dir / CA_CERT)
    assert args[-2:] == ["-out", str(destination / JAVA_CACERTS)]
    assert args[args.index("-passout") + 1] == "pass:changeit"
    assert args[args.index("-jdktrust") + 1] == "anyExtendedKeyUsage"
