"""resolve_path is realpath plus memory: it records what the kernel would
follow, so the sandbox can reproduce the walk. What to bind or replant is
decided in launch_config.

=========================================================================
 @archie-judd READ THIS TO UNDERSTAND THE SYMLINK CHAIN
=========================================================================

Host layout:

    /dir1/dir2/dir3/file.txt       the declared path
    /dir1/dir2 -> dir4             dir2 is a symlink; dir3 and dir4 are
                                   real directories

What resolve_path records (observed; only readlink can know it):

    physical_path   = /dir1/dir4/dir3/file.txt
    parent_symlinks = [ /dir1/dir2 -> /dir1/dir4 ]
    hops            = ()           file.txt itself is not a symlink

What binds.py derives from that (no host access needed):

    --dir     /dir1                          ancestors of physical_path,
    --dir     /dir1/dir4                     created unless some other
    --dir     /dir1/dir4/dir3                bind already covers them
    --bind    /dir1/dir4/dir3/file.txt ...   bound at its physical name
    --symlink /dir1/dir4 /dir1/dir2          the one observed fact

Replay open("/dir1/dir2/dir3/file.txt") inside the sandbox:

    dir1       real directory, created by --dir
    dir2       planted symlink, kernel follows it to /dir1/dir4
    dir4       real directory, created by --dir
    dir3       real directory, created by --dir
    file.txt   the bind: content is here, the open succeeds

If file.txt were additionally a link saying /store/abc/file.txt, the walk
would keep going and record hops = [ /store/abc/file.txt ], and binds.py
would bind content at that name too, so the chase still works when the
declared name arrives inside as a real link instead of being dissolved
into a content bind.

The dividing line: dir3 is legible in the physical path string, so it is
derived downstream, where coverage is known. dir2 -> dir4 is legible only
by readlink on the host, so it is recorded here. parent_symlinks is
exactly the list of facts that would be lost if not observed.
"""

import os
from dataclasses import dataclass
from pathlib import Path

# The kernel spends one 40-follow budget across a whole resolution before
# failing with ELOOP; spending it the same way means a path this walk gives
# up on is one the kernel would have refused too.
MAX_SYMLINK_FOLLOWS = 40


@dataclass(frozen=True, kw_only=True)
class Symlink:
    path: Path
    # What the link says, not where it ends up: absolute, with . and ..
    # collapsed, but keeping any symlink its own text runs through.
    points_to: Path


@dataclass(frozen=True, kw_only=True)
class ResolvedPath:
    # Every parent fully followed, the final name kept as written: whether
    # the path is itself a symlink is a distinction the bind decisions need.
    physical_path: Path
    parent_symlinks: tuple[Symlink, ...]
    hops: tuple[Path, ...]


def _stopped_walk(
    link: Path,
    physical_path: Path | None,
    parent_symlinks: list[Symlink],
    hops: list[Path],
    reason: str,
) -> tuple[ResolvedPath, str]:
    """The resolution as far as the walk got, ending at the link it stopped
    on: never the components behind that link, which sit under a name the
    kernel does not present, so joining them on would invent a path that was
    never resolved."""
    return (
        ResolvedPath(
            physical_path=link if physical_path is None else physical_path,
            parent_symlinks=tuple(parent_symlinks),
            hops=tuple(hops),
        ),
        reason,
    )


def resolve_path(path: Path) -> tuple[ResolvedPath, str | None]:
    """Walk an absolute path as the kernel would, recording every link.

    The second element names the link the walk stopped at, and is None when
    the walk ran to the end. A stopped walk is one the kernel would refuse
    too, so the resolution is as far as it got: the caller decides what to
    do about it rather than reading the partial walk as a whole path.

    One divergence: `.` and `..` are collapsed textually before walking, so
    a `..` written after a symlink is removed as text rather than walked
    through the link the way the kernel would.
    """
    if not path.is_absolute():
        raise ValueError(f"resolve_path needs an absolute path, got '{path}'")

    parent_symlinks: list[Symlink] = []
    hops: list[Path] = []
    follows = 0

    physical_path: Path | None = None

    # True after following a link at the final component. Where that follow
    # lands is not knowable until the target's own parents are walked, so
    # the landing is recorded at the next final component the walk reaches.
    awaiting_hop_landing = False

    normalised = Path(os.path.normpath(path))
    resolved = Path(normalised.anchor)
    remaining = list(normalised.parts[1:])

    while remaining:
        name = remaining.pop(0)
        current = resolved / name
        at_final_component = not remaining

        if at_final_component and physical_path is None:
            physical_path = current
        if at_final_component and awaiting_hop_landing:
            hops.append(current)

        # islink is False for a path that does not exist or cannot be
        # checked, so a broken tail is walked as ordinary names and the
        # existence check downstream reports it.
        if not os.path.islink(current):
            resolved = current
            continue

        try:
            link_text = os.readlink(current)
        except OSError as error:
            return _stopped_walk(
                link=current,
                physical_path=physical_path,
                parent_symlinks=parent_symlinks,
                hops=hops,
                reason=f"{current} could not be read: {error.strerror}",
            )

        target = Path(link_text)
        # A relative link is relative to the directory it sits in, which is
        # exactly `resolved`: everything before it is already physical.
        if not target.is_absolute():
            target = resolved / target
        target = Path(os.path.normpath(target))

        if follows >= MAX_SYMLINK_FOLLOWS:
            return _stopped_walk(
                link=current,
                physical_path=physical_path,
                parent_symlinks=parent_symlinks,
                hops=hops,
                reason=(
                    f"{current} -> {target} could not be followed: "
                    f"too many symlink levels"
                ),
            )
        follows += 1

        if at_final_component:
            awaiting_hop_landing = True
        else:
            parent_symlinks.append(Symlink(path=current, points_to=target))

        # Restart from the root of the target: its own directories may be
        # symlinks too, and each of those needs recording as well.
        remaining = list(target.parts[1:]) + remaining
        resolved = Path(target.anchor)

    if physical_path is None:
        # The walk never reached a final component: the path, or a link's
        # target, was the root itself.
        physical_path = resolved

    return (
        ResolvedPath(
            physical_path=physical_path,
            parent_symlinks=tuple(parent_symlinks),
            hops=tuple(hops),
        ),
        None,
    )
