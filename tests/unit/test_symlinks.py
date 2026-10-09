import errno
import os
from pathlib import Path

import pytest

from launcher.lib.symlinks import MAX_SYMLINK_FOLLOWS, resolve_path


@pytest.fixture
def base(tmp_path: Path) -> Path:
    # realpath so the temporary directory contributes no symlinks of its own
    # to what the walk records.
    return Path(os.path.realpath(tmp_path))


def _build_chain(base: Path, length: int) -> Path:
    """A chain of `length` symlinks ending at a real file, head first."""
    target = base / "target.txt"
    target.touch()
    previous = target
    for index in range(length):
        link = base / f"link{index}"
        link.symlink_to(previous)
        previous = link
    return previous


def test_path_without_symlinks_resolves_unchanged(base: Path) -> None:
    target = base / "file.txt"
    target.touch()

    resolved, unfollowed = resolve_path(target)

    assert unfollowed is None
    assert resolved.physical_path == target
    assert resolved.parent_symlinks == ()
    assert resolved.hops == ()


def test_parent_symlink_is_recorded_and_followed(base: Path) -> None:
    (base / "dir4" / "dir3").mkdir(parents=True)
    (base / "dir4" / "dir3" / "file.txt").touch()
    (base / "dir2").symlink_to(base / "dir4")

    resolved, unfollowed = resolve_path(base / "dir2" / "dir3" / "file.txt")

    assert unfollowed is None
    assert resolved.physical_path == base / "dir4" / "dir3" / "file.txt"
    assert [(link.path, link.points_to) for link in resolved.parent_symlinks] == [
        (base / "dir2", base / "dir4")
    ]


def test_final_component_symlink_records_its_landing(base: Path) -> None:
    target = base / "target.txt"
    target.touch()
    link = base / "link.txt"
    link.symlink_to(target)

    resolved, unfollowed = resolve_path(link)

    assert unfollowed is None
    assert resolved.physical_path == link
    assert resolved.hops == (target,)


def test_chain_within_the_follow_budget_resolves(base: Path) -> None:
    head = _build_chain(base, MAX_SYMLINK_FOLLOWS)

    resolved, unfollowed = resolve_path(head)

    assert unfollowed is None
    assert resolved.physical_path == head


def test_chain_over_the_follow_budget_stops_at_the_last_link(base: Path) -> None:
    head = _build_chain(base, MAX_SYMLINK_FOLLOWS + 1)

    resolved, unfollowed = resolve_path(head)

    # link0 is the last link of the chain and the first one over the budget.
    assert unfollowed == (
        f"{base / 'link0'} -> {base / 'target.txt'} could not be followed: "
        f"too many symlink levels"
    )
    assert resolved.physical_path == head


def test_loop_names_the_link_and_its_target(base: Path) -> None:
    first = base / "first"
    second = base / "second"
    first.symlink_to(second)
    second.symlink_to(first)

    resolved, unfollowed = resolve_path(first)

    assert unfollowed in (
        f"{first} -> {second} could not be followed: too many symlink levels",
        f"{second} -> {first} could not be followed: too many symlink levels",
    )
    assert resolved.physical_path == first


def test_loop_in_a_parent_invents_no_path_behind_the_link(base: Path) -> None:
    loop = base / "loop"
    loop.symlink_to(loop)

    resolved, unfollowed = resolve_path(loop / "child" / "file.txt")

    assert unfollowed == (
        f"{loop} -> {loop} could not be followed: too many symlink levels"
    )
    # The components behind the loop are dropped, not joined onto it: the
    # kernel would never present that path.
    assert resolved.physical_path == loop


def test_unreadable_link_stops_the_walk(
    base: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (base / "real").mkdir()
    (base / "real" / "file.txt").touch()
    link = base / "link"
    link.symlink_to(base / "real")

    def refuse(path: int | str | bytes | os.PathLike[str]) -> str:
        raise OSError(errno.EACCES, os.strerror(errno.EACCES))

    monkeypatch.setattr(os, "readlink", refuse)

    resolved, unfollowed = resolve_path(link / "file.txt")

    assert unfollowed == f"{link} could not be read: Permission denied"
    # Not link/file.txt: the walk stops at the link rather than carrying on
    # underneath a name it could not resolve.
    assert resolved.physical_path == link
