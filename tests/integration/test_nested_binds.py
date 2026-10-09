import os
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch

pytestmark = pytest.mark.darwin


def test_a_nested_bind_is_refused_without_touching_the_host(
    build_sandbox: BuildSandbox, launch: Launch, fake_home: Path
) -> None:
    root = fake_home / ".agent-sandbox-nested-binds"
    nested = root / "git" / "config"
    payload = fake_home / "dotfiles" / "gitconfig"
    nested.parent.mkdir(parents=True)
    payload.parent.mkdir()
    payload.write_text("[user]\n\tname = Test\n")
    nested.symlink_to(payload)

    result = launch(build_sandbox("nested-binds"), "echo unreachable")

    assert result.returncode == 1
    assert "unreachable" not in result.stdout
    real_root = os.path.realpath(root)
    assert f"{real_root}/git/config: declared as roFile" in result.stderr
    assert f"nested inside {real_root}" in result.stderr
    assert nested.is_symlink() and nested.readlink() == payload
    assert nested.read_text() == "[user]\n\tname = Test\n"
    assert sorted(root.rglob("*")) == [root / "git", nested]
