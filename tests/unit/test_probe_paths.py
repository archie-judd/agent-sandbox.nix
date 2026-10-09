import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Mapping

import pytest

from harness.probes import PathOp, probe_paths

PAYLOAD = Path(__file__).resolve().parent.parent / "integration" / "payloads" / "probe_paths.py"

requires_non_root = pytest.mark.skipif(os.geteuid() == 0, reason="root bypasses permissions")


def _probe(*checks: tuple[str, Path]) -> list[str]:
    request = json.dumps([[op, str(path)] for op, path in checks])
    result = subprocess.run(
        [sys.executable, str(PAYLOAD), request], capture_output=True, text=True, check=True
    )
    outcomes: list[str] = json.loads(result.stdout)
    return outcomes


def test_outcomes_follow_the_order_of_the_checks(tmp_path: Path) -> None:
    present = tmp_path / "present"
    present.write_text("content")

    assert _probe(("read", tmp_path / "missing"), ("read", present)) == ["ENOENT", "ok"]


def test_read_and_stat_and_list(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.write_text("content")

    assert _probe(("read", file), ("stat", file), ("list", tmp_path), ("list", file)) == [
        "ok",
        "ok",
        "ok",
        "ENOTDIR",
    ]


@requires_non_root
def test_an_unreadable_file_is_eacces(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.write_text("content")
    file.chmod(0o000)

    assert _probe(("read", file)) == ["EACCES"]


def test_write_leaves_the_content_alone(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.write_text("content")

    assert _probe(("write", file)) == ["ok"]
    assert file.read_text() == "content"


@requires_non_root
def test_write_to_a_read_only_file_is_eacces(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.write_text("content")
    file.chmod(0o444)

    assert _probe(("write", file)) == ["EACCES"]


def test_create_leaves_nothing_behind(tmp_path: Path) -> None:
    assert _probe(("create", tmp_path / "new")) == ["ok"]
    assert not (tmp_path / "new").exists()


@requires_non_root
def test_create_in_a_read_only_directory_is_eacces(tmp_path: Path) -> None:
    directory = tmp_path / "directory"
    directory.mkdir()
    directory.chmod(0o555)

    assert _probe(("create", directory / "new")) == ["EACCES"]


def test_delete_removes_the_file(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.touch()

    assert _probe(("delete", file)) == ["ok"]
    assert not file.exists()


def test_exec(tmp_path: Path) -> None:
    not_executable = tmp_path / "not-executable"
    not_executable.write_text("#!/bin/sh\n")

    assert _probe(
        ("exec", Path("/bin/sh")), ("exec", not_executable), ("exec", tmp_path / "missing")
    ) == ["ok", "EACCES", "ENOENT"]


def _local_launch(
    binary: Path,
    script: str,
    *,
    cwd: Path | None = None,
    home: Path | None = None,
    env: Mapping[str, str] | None = None,
    tty_reply: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), "--norc", "--noprofile", "-c", script],
        env={**os.environ, "PATH": f"{Path(sys.executable).parent}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
    )


def test_probe_paths_maps_each_check_to_its_outcome(tmp_path: Path) -> None:
    present = tmp_path / "it's present"
    present.write_text("content")
    checks: list[tuple[PathOp, Path]] = [("read", present), ("read", tmp_path / "missing")]

    outcomes = probe_paths(_local_launch, Path("/bin/bash"), checks)

    assert outcomes == {checks[0]: "ok", checks[1]: "ENOENT"}


def test_probe_paths_fails_loudly_when_the_launch_fails() -> None:
    def failing_launch(
        binary: Path,
        script: str,
        *,
        cwd: Path | None = None,
        home: Path | None = None,
        env: Mapping[str, str] | None = None,
        tty_reply: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess([], 1, "", "refused")

    with pytest.raises(AssertionError, match="refused"):
        probe_paths(failing_launch, Path("/bin/bash"), [("read", Path("/"))])
