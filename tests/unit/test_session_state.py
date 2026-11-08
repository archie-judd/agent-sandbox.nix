import dataclasses
import json
import os
import subprocess
from pathlib import Path
from typing import Any

import pytest

from harness.builders import make_spec_linux
from launcher.lib.build_spec import CredentialHostSpec, InjectedCredentialSpec, ProxySpec
from launcher.lib.constants import CA_CERT, LAUNCH_PID, SESSION_RETENTION
from launcher.lib.session_state import (
    _prune_sessions_root,
    _start_proxy,
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
