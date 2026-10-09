import subprocess
import sys
from pathlib import Path

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]
DISABLED = "git is disabled for this session"
NOT_A_REPO_SCRIPT = "command -v git >/dev/null && echo has-git; git rev-parse --git-dir || echo NO-REPO"


def _init(path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(path)], check=True)


def test_a_repo_rooted_at_home_is_not_exposed(
    build_sandbox: BuildSandbox, launch: Launch, fake_home: Path
) -> None:
    _init(fake_home)
    (fake_home / "home-secret.txt").write_text("home-secret-content\n")
    project = fake_home / "subdir"
    project.mkdir()
    (project / "project.txt").write_text("project-file\n")
    sandbox = build_sandbox("git-topologies")
    checks: list[tuple[PathOp, Path]] = [
        ("read", fake_home / "home-secret.txt"),
        ("read", project / "project.txt"),
        ("create", project / "new"),
    ]

    git = launch(sandbox, NOT_A_REPO_SCRIPT, cwd=project)
    outcomes = probe_paths(launch, sandbox, checks, cwd=project)

    assert DISABLED in git.stderr
    assert git.stdout.split() == ["has-git", "NO-REPO"]
    assert outcomes == {checks[0]: HIDDEN, checks[1]: "ok", checks[2]: "ok"}


def test_a_repo_rooted_above_home_is_not_exposed(
    build_sandbox: BuildSandbox, launch: Launch, tmp_path: Path
) -> None:
    outer = tmp_path / "outer"
    outer.mkdir()
    _init(outer)
    (outer / "outer-secret.txt").write_text("outer-secret-content\n")
    home = outer / "home"
    project = home / "project"
    project.mkdir(parents=True)
    sandbox = build_sandbox("git-topologies")

    git = launch(sandbox, NOT_A_REPO_SCRIPT, cwd=project, home=home)
    outcomes = probe_paths(
        launch, sandbox, [("read", outer / "outer-secret.txt")], cwd=project, home=home
    )

    assert DISABLED in git.stderr
    assert git.stdout.split() == ["has-git", "NO-REPO"]
    assert outcomes == {("read", outer / "outer-secret.txt"): HIDDEN}
