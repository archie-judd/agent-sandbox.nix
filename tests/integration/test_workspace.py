import os
import sys
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import probe_paths
from launcher.lib.constants import LAUNCH_LOG

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]


def test_the_granted_workspace_is_reported_on_stderr(
    basic_sandbox: Path, launch: Launch, tmp_path: Path
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    result = launch(basic_sandbox, "true", cwd=workspace)

    assert result.returncode == 0, result.stderr
    assert f"workspace: {os.path.realpath(workspace)}" in result.stderr
    assert "workspace:" not in result.stdout


def test_a_symlinked_launch_directory_is_reported_physical(
    basic_sandbox: Path, launch: Launch, tmp_path: Path
) -> None:
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real)

    result = launch(basic_sandbox, "true", cwd=link)

    assert result.returncode == 0, result.stderr
    assert f"workspace: {os.path.realpath(real)}" in result.stderr
    assert f"workspace: {link}" not in result.stderr


def test_a_refused_launch_reports_no_workspace(
    build_sandbox: BuildSandbox, launch: Launch
) -> None:
    result = launch(build_sandbox("basic-sandbox"), "true")

    assert result.returncode == 1
    assert "workspace:" not in result.stderr


@pytest.fixture
def pin_home(tmp_path: Path) -> Path:
    home = tmp_path / "pin-home"
    (home / "pinned").mkdir(parents=True)
    (home / "pinned" / "inside.txt").write_text("pinned-content\n")
    return home


@pytest.fixture
def launch_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "launch"
    directory.mkdir()
    (directory / "outside.txt").write_text("launch-secret\n")
    return directory


def test_a_pinned_workspace_is_where_the_agent_starts(
    build_sandbox: BuildSandbox,
    launch: Launch,
    sessions_root: Path,
    pin_home: Path,
    launch_dir: Path,
) -> None:
    pin = os.path.realpath(pin_home / "pinned")

    result = launch(
        build_sandbox("workspace-pinned"),
        'read -r line < inside.txt && echo "$line"',
        cwd=launch_dir,
        home=pin_home,
    )

    assert result.stdout == "pinned-content\n", result.stderr
    assert f"workspace: {pin}" in result.stderr
    assert "getcwd" not in result.stderr
    (session,) = sessions_root.iterdir()
    log = (session / LAUNCH_LOG).read_text()
    assert f"launch directory:  {launch_dir}" in log
    assert f"workspace:         {pin}" in log


def test_a_pinned_workspace_hides_the_launch_directory(
    build_sandbox: BuildSandbox, launch: Launch, pin_home: Path, launch_dir: Path
) -> None:
    inside = pin_home / "pinned" / "inside.txt"
    outside = launch_dir / "outside.txt"

    outcomes = probe_paths(
        launch,
        build_sandbox("workspace-pinned"),
        [("read", outside), ("read", inside)],
        cwd=launch_dir,
        home=pin_home,
    )

    assert outcomes == {("read", outside): HIDDEN, ("read", inside): "ok"}


def test_a_missing_pin_is_refused(
    build_sandbox: BuildSandbox, launch: Launch, tmp_path: Path, launch_dir: Path
) -> None:
    pin_home = tmp_path / "empty-pin-home"
    pin_home.mkdir()

    result = launch(
        build_sandbox("workspace-pinned"), "true", cwd=launch_dir, home=pin_home
    )

    assert result.returncode == 1
    pin = os.path.realpath(pin_home / "pinned")
    assert f"{pin}: declared as workspaceDir but does not exist" in result.stderr
