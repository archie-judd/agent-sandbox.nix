"""Symlink resolution: one walk that records what the kernel would follow.

The sandbox is built from nothing, so a name exists inside only if something
put it there. When a program opens a path, the kernel walks the name component
by component and follows every symlink it meets on the way; a single name
missing from that walk fails the open with ENOENT even when the file at the
end was bound at its resolved location. Reproducing the walk inside the
sandbox therefore needs the whole trace of it, and os.path.realpath answers
only where a path ends up, never what it went through. That is the one reason
this module exists: resolve_path is realpath plus memory.

The walk meets two kinds of link, and downstream treats them differently.

A link met in directory position (a parent symlink) is a name on the way to
the file. The sandbox replants the link itself, holding the same text the
host link holds, so the kernel's walk inside the sandbox takes the same route
the walk here took.

A link met at the final component (a hop) is the path turning out to be
another name for something else. The sandbox binds the place each hop lands,
so the content exists inside. Hops are recorded as landing places rather than
as link text because landing places are what downstream needs: the last
landing is the bind source for a declared file, and every landing is checked
for being inside the nix store before it is exposed. The route through each
hop's text is not lost, because any link that text runs through is met in
directory position while walking it, and recorded as a parent symlink like
any other.

Like host_state, this module observes and decides nothing: it reads links and
records what it read, and what to bind or replant is decided in launch_config.

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

# The kernel gives up on a resolution after 40 symlink follows in total and
# fails the open with ELOOP. Spending the same budget across the whole walk,
# rather than a fresh budget per link, means a path this walk gives up on is
# one the kernel would have refused too.
MAX_SYMLINK_FOLLOWS = 40


@dataclass(frozen=True, kw_only=True)
class Symlink:
    """A symlink on the host: where it lives, and what it says.

    points_to is absolute, with . and .. collapsed, but keeps any symlink its
    own text runs through. It is what the link says, not where it ends up.
    Both halves matter: replanting the link inside the sandbox uses this text,
    and the walk that recorded it kept going through the text to record
    whatever else it runs through.
    """

    path: Path
    points_to: Path


@dataclass(frozen=True, kw_only=True)
class ResolvedPath:
    """Everything the kernel would find, and follow, opening one path.

    physical_path is the path with every parent directory resolved to its
    fully-followed form and the final name kept as written. The final name is
    kept because whether the path is itself a symlink is a distinction the
    bind decisions depend on, and resolving it away would destroy the name
    the sandboxed process is going to open.

    parent_symlinks are the links met in directory position, in the order the
    walk met them, including any met while walking the text of another link.
    Duplicates are possible when two links route through the same directory;
    downstream deduplicates as it plants, so the record here stays a plain
    trace of the walk.

    hops are where the final component landed, one entry per dereference,
    each in the same parents-resolved-name-kept form as physical_path. The
    chain is as long as the aliasing is deep: for file -> a -> b with b a
    real file, hops holds the physical forms of a and then b, and the last
    entry is the real file the content lives at. hops is empty exactly when
    the path is not a symlink, so there is no is_symlink field beside it:
    two ways to state one fact is two ways for it to disagree with itself.
    """

    physical_path: Path
    parent_symlinks: tuple[Symlink, ...]
    hops: tuple[Path, ...]


def resolve_path(path: Path) -> ResolvedPath:
    """Walk an absolute path as the kernel would, recording every link.

    The walk keeps two pieces of state. `resolved` is the prefix already
    known to be physical: it starts at the root and grows one component at a
    time, and no symlink ever survives into it. `remaining` holds the
    components still to walk. Meeting a symlink replaces the walk: the
    link's target is pushed onto the front of `remaining` and the walk
    restarts from the root, because the target's own directories may be
    symlinks too and each of those needs recording as well.

    Only an absolute path can be walked. A relative one would have to be
    resolved against some base directory first, and choosing that base is
    the caller's decision, not this module's.

    Three policies, stated here because each replaces behaviour that used to
    be implicit or to differ between two walks:

    - The follow budget is one counter for the whole walk, like the
      kernel's. On exhaustion the walk stops and returns what it has, with
      the physical path still naming what the caller asked about; the
      kernel would have failed the open with ELOOP, and the existence check
      downstream fails the returned name instead.

    - A link that vanishes between the check and the read is walked as an
      ordinary name. Whatever is or is not there now, the existence check
      downstream reports it.

    - `.` and `..` are collapsed textually before walking, in the path and
      in every link target. A `..` written after a symlink is therefore
      removed as text rather than walked through the link the way the
      kernel would. This is parity with the walk it replaces, kept so that
      the only change here is shape, not behaviour.
    """
    if not path.is_absolute():
        raise ValueError(f"resolve_path needs an absolute path, got '{path}'")

    parent_symlinks: list[Symlink] = []
    hops: list[Path] = []
    follows = 0

    # Set at the first final-component visit, which is the moment `resolved`
    # holds the fully-followed form of every parent and `name` is still the
    # name as written. The walk may continue past that moment, but only to
    # collect hops; the physical path itself never changes again.
    physical_path: Path | None = None

    # True after following a link at the final component. Where that follow
    # lands is not knowable at follow time, because the target's own parents
    # still need walking; the landing is the next final component the walk
    # reaches, and it is recorded when the walk reaches it.
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
        # existence check downstream reports whatever is wrong with it.
        if not os.path.islink(current):
            resolved = current
            continue

        if follows >= MAX_SYMLINK_FOLLOWS:
            if physical_path is None:
                physical_path = current.joinpath(*remaining)
            return ResolvedPath(
                physical_path=physical_path,
                parent_symlinks=tuple(parent_symlinks),
                hops=tuple(hops),
            )
        follows += 1

        try:
            link_text = os.readlink(current)
        except OSError:
            resolved = current
            continue

        target = Path(link_text)
        # A relative link is relative to the directory the link itself sits
        # in, which is exactly `resolved`: every component before this one
        # has already been walked to its physical form.
        if not target.is_absolute():
            target = resolved / target
        target = Path(os.path.normpath(target))

        if at_final_component:
            awaiting_hop_landing = True
        else:
            parent_symlinks.append(Symlink(path=current, points_to=target))

        # Restart from the root of the target. Components the target shares
        # with ground already walked get walked again; that repetition buys
        # the guarantee that nothing in `resolved` is ever a symlink.
        remaining = list(target.parts[1:]) + remaining
        resolved = Path(target.anchor)

    if physical_path is None:
        # The walk never reached a final component. Either the path was the
        # root itself, or a link's target was the root and spliced nothing,
        # ending the walk while a landing was still awaited; the landing
        # would have been the root, which is never a hop worth recording.
        physical_path = resolved

    return ResolvedPath(
        physical_path=physical_path,
        parent_symlinks=tuple(parent_symlinks),
        hops=tuple(hops),
    )
