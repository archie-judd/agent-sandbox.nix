import os
import shlex
import subprocess
import sys
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.listeners import tcp_listener
from harness.ports import DRIVER_PORT, HTTPBIN_PORT, MARIONETTE_PORT, WEBSOCKET_PORT

PAYLOADS = Path(__file__).resolve().parent / "payloads"
WEBDRIVER = (PAYLOADS / "inside-webdriver-title.sh").read_text()
LAUNCHSERVICES_PROBE = PAYLOADS / "probe_launchservices.py"
LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/"
    "LaunchServices.framework/Versions/A/Support/lsregister"
)


def _webdriver(browser: str, url: str = "") -> str:
    args = [browser, str(DRIVER_PORT), str(MARIONETTE_PORT), str(WEBSOCKET_PORT)]
    if url:
        args.append(url)
    return f"bash -c {shlex.quote(WEBDRIVER)} webdriver {shlex.join(args)}"


@pytest.mark.parametrize("browser", ["chrome", "firefox"])
def test_a_headless_browser_runs_a_webdriver_session(
    build_sandbox: BuildSandbox, launch: Launch, browser: str
) -> None:
    result = launch(build_sandbox("headless-browser", {"browser": browser}), _webdriver(browser))

    assert result.returncode == 0, result.stderr
    assert '"value":"headless-ok"' in result.stdout


@pytest.mark.parametrize(
    "browser", ["chrome", "firefox", pytest.param("chromium", marks=pytest.mark.linux)]
)
def test_https_goes_through_the_proxy_and_only_to_allowed_domains(
    build_sandbox: BuildSandbox, launch: Launch, browser: str
) -> None:
    sandbox = build_sandbox(
        "headless-browser", {"browser": browser, "httpbinPort": str(HTTPBIN_PORT)}
    )

    with tcp_listener(HTTPBIN_PORT):
        allowed = launch(sandbox, _webdriver(browser, "https://httpbin.test/html"))
        blocked = launch(sandbox, _webdriver(browser, "https://blocked.test/"))

    assert allowed.returncode == 0, allowed.stderr
    assert '"value":"ok"' in allowed.stdout
    assert blocked.returncode == 1, blocked.stderr
    assert '"value":"ok"' not in blocked.stdout
    if browser != "firefox":
        assert "ERR_TUNNEL_CONNECTION_FAILED" in blocked.stdout


def _host_probe(*args: str) -> int:
    return subprocess.run(
        [sys.executable, str(LAUNCHSERVICES_PROBE), *args], capture_output=True
    ).returncode


@pytest.fixture
def lures(tmp_path: Path) -> Iterator[tuple[Path, Path, str]]:
    workspace = tmp_path / "workspace"
    markers = tmp_path / "markers"
    workspace.mkdir()
    markers.mkdir()
    scheme = f"sbxtest-{os.getpid()}"
    command = workspace / "escape.command"
    command.write_text(f'#!/bin/sh\ntouch "{markers}/escaped"\n')
    command.chmod(0o755)
    app = workspace / "Sbx.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "MacOS" / "sbx").write_text(f'#!/bin/sh\ntouch "{markers}/handled"\n')
    (app / "Contents" / "MacOS" / "sbx").chmod(0o755)
    (app / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n'
        f"  <key>CFBundleIdentifier</key><string>test.{scheme}</string>\n"
        "  <key>CFBundleExecutable</key><string>sbx</string>\n"
        "  <key>CFBundlePackageType</key><string>APPL</string>\n"
        "  <key>CFBundleURLTypes</key><array><dict>\n"
        f"    <key>CFBundleURLSchemes</key><array><string>{scheme}</string></array>\n"
        "  </dict></array>\n</dict></plist>\n"
    )
    yield workspace, markers, scheme
    subprocess.run([str(LSREGISTER), "-u", str(app)], capture_output=True)


@pytest.mark.darwin
def test_launchservices_stays_closed_to_the_sandbox(
    build_sandbox: BuildSandbox, launch: Launch, lures: tuple[Path, Path, str]
) -> None:
    workspace, markers, scheme = lures
    assert _host_probe("bundle", "com.apple.calculator") == 0
    probe = f"python3 -c {shlex.quote(LAUNCHSERVICES_PROBE.read_text())}"
    attempts = {
        "open-calculator": "open /System/Applications/Calculator.app",
        "open-command": f"open {shlex.quote(str(workspace / 'escape.command'))}",
        "register-app": f"register {shlex.quote(str(workspace / 'Sbx.app'))}",
        "read-database": "bundle com.apple.calculator",
    }
    script = "\n".join(f'{probe} {args} >/dev/null 2>&1; echo "{label} $?"' for label, args in attempts.items())

    result = launch(build_sandbox("headless-browser", {"browser": "chrome"}), script, cwd=workspace)
    time.sleep(3)

    statuses = dict(line.split() for line in result.stdout.splitlines())
    assert statuses.keys() == attempts.keys(), result.stderr
    assert all(status != "0" for status in statuses.values()), statuses
    assert not (markers / "escaped").exists()
    assert _host_probe("handler", f"{scheme}://x") != 0
