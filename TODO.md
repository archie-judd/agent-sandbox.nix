# Restructure and debug logging plan

Two goals, in one sequence. First, give the wrapper a readable source so that
changes to it can be reviewed as a diff and linted in CI. Second, add per-run
debug artifacts so a failed launch leaves behind enough to diagnose it without
reproducing it.

The order matters: the debug artifacts describe the sandbox completely, so
building them early turns the restructure into a mechanical change verified by
diff rather than a rewrite verified by hope.

## The problem being solved

The wrapper script has no source file. It exists only as the concatenation of
around twenty Nix-interpolated fragments spliced into one flat top-level scope,
and those fragments communicate through globals defined in other files. Reading
the macOS launch means knowing that `ancestorTraversalBashStr` sets
`ANCESTOR_DIRS`, that `ancestorProfilePatchBashStr` consumes it and sets
`SANDBOX_PROFILE`, that `gitProtectionProfilePatchBashStr` consumes that plus
`GIT_PROTECTED_DIRS` from `lib/shared.nix`, and that `networkRuntimePatchBashStr`
in `lib/darwin/networking.nix` also appends to `SANDBOX_PROFILE` and depends on
`_PROXY_PORT` set back in `lib/shared.nix`. Five files, four implicit globals,
one ordering constraint enforced nowhere. The header comment in
`lib/linux/symlink-helpers.nix` documents that constraint in prose because
nothing else can.

Consequences: no shellcheck (the code is Nix strings), no unit tests (the
functions cannot be called without building and launching a sandbox), and PR
review means reading a diff of a string embedded in a Nix expression.

## The target shape

Nix generates a data prelude, which sources a real `.sh` file of functions.

The prelude holds every store path, every constant and every user-supplied list,
interpolated by Nix so string context is preserved and `writeClosure` keeps
working. The `.sh` holds the logic and contains no store paths at all, so it
needs no string context. This split is the reason the migration is possible:
`builtins.readFile` returns a string with no context, so a store path written
literally into a `.sh` file would not be tracked as a runtime dependency and
could be garbage collected.

Counting every Nix interpolation in `lib/` shows the migration is smaller than
it looks. Around fifty are fragment splices, which are deleted rather than
migrated. Around seventy-six are loop variables (`p.name` 23 times, `dir` 17,
`file` 16) where Nix is doing a loop that bash should do, and which collapse
into array iteration. Only around eighty-three are genuine constants, covering
about twenty-one distinct values.

Two rules keep the split honest:

Nix decides what enters the closure, the `.sh` decides control flow. Build-time
branches become conditional data binding, not conditional code. `sandbox-proxy`
is referenced only from the restricted branch today, so an unrestricted wrapper
does not carry the Go proxy in its closure. The prelude preserves that by
emitting the proxy path only when `allowedDomains` is set, with the `.sh`
branching on whether the variable is bound.

Store paths and prefixes become readonly ambient constants, not function
parameters. Threading a git path through every signature would be noise. What
becomes parameters is the runtime state currently moving through mutable
globals: `BOUND_PREFIXES`, `SANDBOX_PROFILE`, `GIT_PROTECTED_DIRS`,
`STATE_FILE_BINDS`, `RESOLVED_TARGETS`, `SEEN_PARENT_DIRS`, `ANCESTOR_DIRS`.

### Function documentation

Every function in a `.sh` file carries a Google Shell Style Guide header: a
one-line description, then `Globals:`, `Arguments:`, `Outputs:` and `Returns:`
naming what it reads, takes, writes and exits with. Sections that do not apply
say `None` rather than being left out.

With the `####` separator rows above and below the block, as Google writes
them:

```bash
#######################################
# Checks whether a path is already covered by a bound prefix.
# Globals:
#   BOUND_PREFIXES
# Arguments:
#   Path to test, absolute.
# Outputs:
#   None
# Returns:
#   0 if covered by a bound prefix, 1 otherwise.
#######################################
is_already_bound() {
```

The `Globals:` section earns its place here specifically. The defect this
restructure exists to fix is functions communicating through undeclared globals,
so a convention that forces each one to be listed puts the remaining coupling at
the top of the function instead of leaving it to be found by reading. A long
`Globals:` list is the signal that the function wants parameters instead, which
makes the convention a design check rather than decoration.

Nothing enforces it. shellcheck has no opinion on doc comments, so this is a
review convention, and the acceptance criteria for units 4, 5 and 6 name it.

### Naming

A leading underscore marks a function or variable as internal to its `.sh` file,
callable only by other functions in the same file. Anything the wrapper itself
calls, or that crosses from one file to another, carries no prefix. Today every
function is prefixed regardless (`_is_already_bound`, `_follow_symlink_chain`,
`_add_symlink_target`, `_ensure_parent_dirs`), so the prefix distinguishes
nothing.

It starts paying once the `.sh` files divide into modules and the longer
functions decompose into helpers that exist only to serve one caller. At that
point the prefix is what tells a reader which names are a module's surface and
which are its interior, so the rule is worth applying from unit 4 even while
there is only one file and little for it to separate.

Names are re-evaluated for explicitness as part of the move, not carried over
out of habit. The current set is inconsistent in ways that only survived because
nothing forced a second look: `readonlyStateFileSymlinks` is lower camel case
among upper snake case globals, `STATE_DIR_BINDS` and `STATE_FILE_BINDS` are
named for a `stateDirs` argument that became `rwDirs`, and `RESOLVED_TARGETS`
does not say resolved from what.

Renaming is free against the acceptance criteria. Names do not reach the
bubblewrap args file or the seatbelt profile, so a rename cannot change a golden
diff. It does make the PR diff harder to read, since a rename and a logic change
look alike, which is a further reason the golden files come first.

Proposed names are batched for the maintainer to confirm before being used, not
chosen in passing while writing the code. The Names to confirm section below is
where they go.

## Debug logging shape

One directory per launch:

```
$XDG_STATE_HOME/agent-sandbox/<timestamp>-<pid>-<outName>/
  startup.log    # appended as the wrapper goes, both platforms
  proxy.log      # proxy stderr, only when allowedDomains is set
  bwrap.args     # Linux: the NUL-separated bubblewrap args file
  seatbelt.sb    # macOS: the runtime-patched seatbelt profile
```

Retention is 25 run directories, pruned at launch. The number is a constant in
`lib/shared.nix`, not a `mkSandbox` argument. `AGENT_SANDBOX_LOG_DIR` overrides
the log root, which the tests need so a full run does not fill the developer's
real state directory and evict real sessions.

### Decisions carried forward

No toggle and no Nix argument. Everything logged is cheap, bounded and already
computed; a toggle you must set before the failure means reproducing the failure
first, which is the thing that is hard about sandbox bugs.

Proxy allow-side logging (a record of every URL the agent fetched) is out of
scope. It is high volume, and it would stop the run directory being safe to
attach to a GitHub issue, which is the property the rest of the design is built
around. If it is added later it brings its own opt-in.

Logging is best effort and never gates a launch. An unwritable log root, a
failed mkdir or a failed append must all leave the sandbox running normally.
This inverts the convention in the surrounding code (`assertBindsExistBashStr`
exits 1 on a missing bind) and needs a comment saying so.

The wrapper prints nothing about the run directory, on success or failure.
Discoverability is the README's job.

The spec dump added in unit 3 is a separate thing and does not reopen this
decision. It is a test facility that writes the resolved configuration and exits
without launching. The rejected toggle was about users needing artifacts from a
failure they have already hit.

## Security fixes, ahead of unit 0

Independent of the restructure, and not scheduled against it. A fork at
https://github.com/ofekd/agent-sandbox.nix/commits/hardening/ found a set of
real defects; these are the ones that ship before anything else here. That fork
is based on 2.3.0 and main is five commits ahead of its fork point, so its git
protection fixes are wholly or partly superseded by 147d9af and are not listed.

### S1. Proxy fixes

Done. 4 files.

`proxy/main.go` and `proxy/main_test.go`, plus `tests/shared/test-proxy-unit.sh`
to run the new tests and the README's statement of what method filtering
guarantees. No interaction with any unit below, since the plan never touches the
proxy.

Three defects. `net.Dial("tcp", addr)` dials the resolved name with no address
vetting, so an allowlisted domain resolving to a loopback ~~or RFC1918~~ address
reaches exactly the host services `allowedLocalPorts` exists to gate. Resolve
once, reject the answer if any address is loopback, link-local, ~~private~~ or an
IPv4-mapped form of one, then dial a vetted literal so a rebind between check and
connect has nothing to win.

Scope narrowed on implementation: private ranges (10/8, 172.16/12, 192.168/16,
fc00::/7) are deliberately left dialable. They are the network around the host
rather than the host itself, allowlisting an internal company server by name is
a legitimate configuration, and `allowedLocalPorts` cannot express it. Blocking
them would have needed an opt-out argument, which is wider than S1. The
loopback, link-local and unspecified cases are refused, which is what the
README's promise that `allowedDomains` never grants host-local access requires.

The `SANDBOX_PROXY_REDIRECT` path skips vetting. It is the test harness's escape
hatch and points at a local httpbin on purpose, so vetting it would break every
network test.

Request bodies are never inspected and are forwarded verbatim, so a `[ GET ]`
policy is not read-only. Refuse GET and HEAD carrying a body, detecting both
`Content-Length` and chunked framing.

The method is uppercased in `isMethodAllowed` but compared exact-case for the
URL cap, so `curl -X get` passes the policy and skips the cap. Normalise once at
the top and use it for both. `maxURLBytes` should apply to every method, not
only GET and HEAD. The CONNECT dispatch stays exact-case deliberately.

The tests are Go unit tests, the first in the repo. `tests/run-all.sh` picks
them up through its existing `shared/test-*.sh` glob, so CI runs them with no
workflow change.

Acceptance: the suite passes, plus new tests that an allowlisted domain
resolving to a loopback ~~or private~~ address is refused, that a GET carrying a
body is refused under a GET-only policy in both the `Content-Length` and chunked
framings, that `-X get` with a body is refused by the same guard, and that the
URL cap applies to POST.

### S2. Refuse nested binds on macOS

Done. 3 files.

`lib/darwin/default.nix`, plus `tests/darwin/test-nested-binds-refused.sh` and
`tests/fixtures/nested-binds.nix`. Small, and deliberately not the full fix.

`mkSymlinkHomeMappingStr` plants each declared bind into the sandbox HOME in
declaration order. `mkdir -p` follows a symlink planted earlier in the same
loop out into the real home, and `ln -sfn` then unlinks a destination that
resolves through it. Declaring one bind inside another destroys the user's real
file at launch, with no agent involved. It is reachable from the git identity
setup the README recommends: a `roFiles` entry for the git config under any
`rwDirs` entry on an ancestor.

Fix the damage, not the ergonomics. Before planting, walk each path component
from the sandbox HOME down and refuse if any component is already a symlink or
not a directory. Erroring out on a nested declaration is a behaviour change and
belongs in the release notes, but it stops the data loss in around thirty lines
and leaves almost nothing for unit 6 to unpick.

Resolving nesting properly (register every bind first, plant shallowest-first,
refuse only where two declarations genuinely disagree about the host path) is
unit 9. It is far cheaper written against the restructured code.

Scope on implementation: the walk also refuses when the bind's own destination
in the sandbox HOME is already occupied. Without that, the reverse declaration
order (the inner path declared first, its ancestor second) still plants the
ancestor one level too deep and the bind silently does not exist inside the
sandbox. Declaring the same path twice is refused by the same check.

The `ln` on the host happens to survive one shape of this: where the declared
file is a plain file, source and destination resolve to the same inode and GNU
`ln` refuses. The destructive shape is a declared file that is itself a host
symlink (a dotfiles setup), which is replaced by a link pointing at itself.

The README gains one sentence, since the refusal is user-facing. The behaviour
change is recorded in the commit message for the release notes.

Acceptance: the suite passes, plus a new test that a `roFiles` entry declared
under an `rwDirs` ancestor refuses at launch and leaves the real host file
byte-identical.

## Units

Each unit is one PR. File counts exclude generated golden files, which are
counted separately because they are not read in review.

### 0. Fix the macOS EXIT trap

Not started. 2 files. 0.5 days.

`lib/darwin/networking.nix` sets `sandboxExecBashStr = "exec "` in the
unrestricted branch, so the shell is replaced and the EXIT trap set by
`bashTrapCleanupStr` never fires. On the default macOS config (no
`allowedDomains`) nothing is cleaned up: `$SANDBOX_HOME`, `$SANDBOX_PROFILE` and
`$_SANDBOX_PASSWD` all survive every run. There were 165 of each left on the
development machine.

This breaks a documented promise. On Linux `$HOME` is a real tmpfs and
disappears structurally; on macOS the `rm -rf` is the only thing making it
ephemeral.

Fix: drop `exec ` so both branches keep the wrapper shell as parent, which is
what the restricted branch already does. Add a test asserting no
`/private/tmp/sandbox-home.*` survives an unrestricted run.

Ships first and alone, so it can be backported.

Acceptance: the suite passes, plus a new test that no
`/private/tmp/sandbox-home.*` survives an unrestricted run.

### 1. Convert the bubblewrap invocation to `--args`

Not started. 3 files. 2 days.

`bwrap --args FD` parses NUL-separated arguments from a file descriptor, so the
whole configuration can live in a file. That file becomes the Linux counterpart
to the seatbelt profile, and unlike a rendered command line it can be fed back
to bubblewrap to reproduce a session by hand. It is also what unit 3 diffs.

This is also a correctness fix. `lib/linux/symlink-helpers.nix` builds
`STATE_DIR_BINDS="$STATE_DIR_BINDS --bind ${dir} ${dir}"` and
`lib/linux/default.nix` expands it unquoted, so a declared path containing
whitespace splits into several bubblewrap arguments. At best the bind is wrong;
at worst a path whose second field begins with `--` injects a flag.
`GIT_PROTECT_BINDS` is already an array and already safe, nothing else is.

Work:

- Convert `REPO_BIND`, `STATE_DIR_BINDS`, `RO_DIR_BINDS`, `STATE_FILE_BINDS`,
  `RO_FILE_BINDS`, `SYMLINK_PARENT_DIRS` and `readonlyStateFileSymlinks` to bash
  arrays, in both `lib/linux/default.nix` and `lib/linux/symlink-helpers.nix`.
  Also `CLOSURE_BINDS`, which is safe today because store paths hold no
  whitespace, but which should not be the one exception left behind.
- Convert the Nix-generated fragments the same way: `nixStoreBwrapStr`,
  `nixDaemonSocketBwrapStr`, and from `lib/linux/networking.nix` the
  `etcResolvBind`, `caCertBubblewrapStr`, `proxyEnvBubblewrapStr` and
  `sslCertEnvBubblewrapStr`. These embed shell quoting (`--ro-bind "$_COMBINED_CA_BUNDLE" /tmp/...`) that currently means "shell, expand this".
  There is no shell reading an args file, so each becomes a bash append that
  expands the variable and writes one NUL-terminated field.
- Write the array NUL-separated to a `mktemp` path and launch with
  `bwrap --args 3 3< "$file"`.

The file stays NUL-separated end to end. Writing it newline-separated and
converting with `tr` would reintroduce the injection vector for any path
containing a newline.

User `env` stays on the command line as `--setenv` arguments rather than moving
into the args file. That keeps the file free of secrets, so it can be copied
into the run directory verbatim and replayed. The alternative (everything in the
file, redacted copy in the run directory) would get secrets out of
`/proc/<pid>/cmdline`, but that exposure is not in the threat model: with
`--unshare-all` and `--proc /proc` the sandboxed agent sees only its own PID
namespace. Exposure to other same-UID host processes is a pre-existing
shared-host concern, separate from this work.

Verify `--args` against the pinned nixpkgs first: `bwrap --help | grep -- '--args'`.

The fork's `d97705a` is an independent implementation of the array conversion
against 2.3.0. Worth diffing against once this is written, since this is the
riskiest of the early units and a second opinion on it is free.

Acceptance: the suite passes, plus new tests that a declared path containing
whitespace reaches bubblewrap as a single argument, and that a path whose second
field begins with `--` does not become a flag.

### 2. Test housekeeping

Not started. Around 25 files, almost all mechanical. 1 day.

Three unrelated fixes to the suite, batched because they all touch it and none
is worth its own PR.

Pin the fixtures' nixpkgs. 21 of the 22 files in `tests/fixtures/` do
`pkgs = import <nixpkgs> { }`, which is the ambient channel, not the flake's
pinned `nixos-unstable`, and nothing in `tests/` or `.github/workflows/test.yml`
sets `NIX_PATH`. The suite therefore builds against whatever nixpkgs happens to
be on the machine, so a CI failure need not reproduce locally. This is also a
hard blocker for unit 3: store paths and package versions land in the dumped
spec, so unpinned fixtures produce a different golden file on every machine.

Make the test harness contract explicit. `tests/lib.sh` calls a `run()` function
that each test file is expected to define as an undeclared global hook, and
`expect_ok` invokes it as `run "$*"`, flattening its arguments into one string
so quoting is silently lossy. A test file can redefine `run` halfway down to
switch which sandbox it asserts against, which is invisible in review. This is
the same ambient-contract problem as the wrapper and wants the same fix.

Hoist the builds. Each test file runs its own `nix-build`, so evaluation happens
around thirty times per suite. Build once in `tests/run-all.sh` and pass paths
down.

Acceptance: the suite passes, and passes identically on a machine whose
ambient `<nixpkgs>` differs from the pin. Nothing under `lib/` changes.

### 3. Spec dump and golden files

Not started. 7 files, plus around 22 generated goldens. 2 days.

A mode that resolves the full sandbox configuration and writes it out without
launching. On Linux that is the args file from unit 1. On macOS it is
`$SANDBOX_PROFILE` after `ancestorProfilePatchBashStr`,
`gitProtectionProfilePatchBashStr` and `networkRuntimePatchBashStr` have all
appended to it.

Also needed: a normalizer that strips store hashes, `mktemp` suffixes, the proxy
port and `$SANDBOX_HOME` from the dump, or the goldens churn on every unrelated
change. And a test that dumps each fixture, normalizes, and diffs against a
checked-in file, with a documented command to regenerate.

This is the unit that pays for itself twice. It makes units 5 and 6 verifiable
by diff rather than by reasoning, and it makes a contributor's PR reviewable as
a change to a checked-in file. A change like `allowGpu` amounts to two bwrap
flags; seeing `--dev-bind-try /dev/dri /dev/dri --ro-bind-try /sys /sys` appear
in a golden file is the whole review.

Note the tier boundary, which must not blur: goldens prove the wrapper passed
the right arguments, and only end-to-end tests prove the kernel enforced them.
`test-git-hook-injection`, `test-rodirs-symlink-hardening`,
`test-user-folders-denied` and `test-nix-store-isolation` stay end-to-end
permanently. Converting an enforcement test into a golden diff would look like a
speedup and be a security regression in the suite.

Acceptance: the suite passes, a golden file exists for every fixture, and the
regenerate command reproduces them byte-identically on a second machine.

### 4. Pilot: move the shared bash to `.sh` files

Not started. 5 files. 1.5 days.

`lib/shared.nix` is the smallest surface that exercises the whole pattern, and
it is shared by both backends so it has to move before either of them.
`assertBindsExistBashStr` becomes a loop over an array instead of one generated
`if` per path. `gitProtectedPathsBashStr` becomes a function returning its two
lists explicitly. `assertHomeCwdAllowedBashStr` and `mkProxyStartupBashStr` move
as they are.

The point of doing this first is to settle the conventions (where the file is
sourced, how arrays are passed and returned, how the conditional data binding
reads, and the function documentation and naming rules described above) on a
piece small enough to throw away if they turn out wrong.

After this `lib/shared.nix` should be close to genuine Nix only: `bashWrapper`,
`mkAllowlistFile`, `validateAllowedLocalPorts`, `assertNoLegacyArgs`. The split
into separate files that goal 2 originally called for mostly stops being
necessary at that size, so decide it then rather than now.

Acceptance: the suite passes, the golden diff is empty, and the new `.sh` files follow the
conventions in Function documentation and Naming.

### 5. Restructure the Linux wrapper

Not started. 4 files. 3 to 4 days.

The generated wrapper becomes a prelude plus a source of one `.sh`.
`lib/linux/symlink-helpers.nix` largely disappears: `isAlreadyBoundBashStr`,
`addSymlinkTargetBashStr` and `followSymlinkChainBashStr` are already real bash
functions and move nearly unchanged, while the five `mkResolve*BashStr`
generators and `mkScanDirBashStr` collapse into loops over the prelude's arrays.

The globals listed in the target shape section become parameters and returns.
The two branches of `lib/linux/networking.nix`, currently two parallel attrsets
with matching key sets, become one code path with conditional data.

Estimate is the least reliable in this plan. Bubblewrap is order-sensitive about
mount destinations, and `mkResolveFileBashStr` documents a case where no
ordering of the binds works at all, so some of the apparent repetition may turn
out to be load-bearing.

Acceptance: the suite passes, the golden diff against unit 3 is empty, and the new `.sh` files follow the
conventions in Function documentation and Naming.

### 6. Restructure the macOS wrapper

Not started. 3 files. 3 days.

Same shape. The four `mkSymlinkHomeMappingStr` call sites collapse into one
loop, as do the four traversal blocks in `ancestorTraversalBashStr` and the
eight `resolve*Str` / `*Flags` generators.

The indexed seatbelt params (`STATE_DIR_0` through `STATE_DIR_N`) are the one
genuinely build-time-shaped thing here, since the profile is a Nix-built file
that must name each param. They can stay as they are; the profile is generated
data, not logic, and leaving it alone keeps this PR to the wrapper. Worth noting
for later that the profile is already appended to at runtime in three places, so
the indexed params are a convention rather than a constraint.

Acceptance: the suite passes, the golden diff is empty, and the new `.sh` files follow the
conventions in Function documentation and Naming.

### 7. Unit test tier and shellcheck

Not started. 6 files. 2 days.

With real `.sh` files, the functions can be sourced with a stub prelude and
called directly against a tmpdir, with no `nix-build` and no sandbox launch.
Cover the symlink chain walk, the bound-prefix check, parent-dir emission and
the git protected-path enumeration.

Most of this runs on macOS against the Linux logic, since it is path
manipulation plus `readlink`, `find` and `git`. That is the point: a macOS
maintainer currently has no way to execute the Linux code they are reviewing.

Add shellcheck to `.github/workflows/test.yml`. It permanently catches the class
of bug that unit 1 fixes by hand.

Open decision: whether the unit tier uses bats or extends `tests/lib.sh`.
Extending `lib.sh` keeps the suite dependency-free, which matters for a tool
people run before trusting it.

Acceptance: the suite passes, shellcheck runs clean in CI, and the unit tier
covers the symlink chain walk, the bound-prefix check, parent-dir emission and
the git protected-path enumeration, running on macOS as well as Linux.

### 8. Debug logging

Not started. Around 10 files. 3 days.

Now on the restructured wrapper, so this is wiring rather than surgery.

Run directory plumbing in the shared code: resolve the log root
(`AGENT_SANDBOX_LOG_DIR`, else `$XDG_STATE_HOME`, else `$HOME/.local/state`),
prune all but the newest 25, create this run's directory, define the append
helper. Called first thing in both wrappers, ahead of the bind-existence check,
so a run refused for a missing bind or a declined home-directory launch still
records why. Timestamp leads the directory name so `ls` sorts chronologically
and pruning by name matches pruning by mtime. `outName` is included because
several wrappers share one log root.

Warn at launch if a declared `rwDir` or `rwFile` covers the log root, since that
would hand the agent write access to its own logs.

Generate a keys-only rendering of the user `env` attrset in Nix, alongside the
values passed to the launch, so `startup.log` records which variables were
passed without their values. Building it from the same attrset at build time
means it cannot be defeated by a value that happens to look like a flag.

Append to `startup.log` at each stage boundary as state becomes available:
resolved config, bind-existence result, home-cwd decision, `GIT_DIR` and
`REPO_ROOT`, the git protected paths, nix store and symlink resolution, proxy
port, env keys, and the launch line. On macOS also the TTY detection, ancestor
dirs, `SANDBOX_HOME` and the resolved read-write and read-only paths.

Copy the args file and the patched seatbelt profile into the run directory, best
effort. The launch still reads the `mktemp` original, so an unwritable log root
cannot break it, and the trap removes the original as before. `$SANDBOX_HOME` is
not preserved.

Point the proxy's stderr at the run directory instead of
`/tmp/sandbox-proxy.log`. No changes to the Go proxy. Extend the exit trap to
append the exit status.

Tests: run directory created and populated on success; populated on early
failure (a missing `rwDir`); secrets absent from the args file; retention prunes
to 25; an unwritable log root does not fail the launch. `tests/run-all.sh` sets
`AGENT_SANDBOX_LOG_DIR` to a scratch path.

README: replace the `tail -f /tmp/sandbox-proxy.log` instruction in
Troubleshooting, describe the run directory as the thing to attach to an issue,
document `tr '\0' '\n' < bwrap.args` for reading the Linux args file and
`bwrap --args` for replaying it, and state that on macOS the sandbox can read
and write host `/tmp` but not the log root, which is why the logs moved out of
`/tmp`.

Acceptance: the suite passes, including the new tests above.

### 9. Security backlog

Not started. Around 6 files. 2 days.

The fork's remaining findings, deferred to here because each lands in code that
units 5 and 6 rewrite, and none is losing data today. Written against the
restructured wrapper they are small; written now they would be thrown away.

The symlink walk continues from an invented cursor when a hop cannot be
resolved. The `|| true` meant to catch it is dead, because an assignment takes
its status from the last command substitution, and `basename` always succeeds.
The consequence is store paths bound that nobody declared, and silently skipped
hops where the invented name happens to match a bound prefix. Unit 5 deletes
this function outright, which is why it waits.

Launcher-derived paths are not resolved to physical form before becoming
seatbelt rules, and the kernel resolves symlinks before the seatbelt hook, so
rules against a path under `/tmp` or a symlinked home silently match nothing.

The macOS profile grants blanket `file-write*` on `/tmp` and `/private/tmp`,
where the launcher keeps the CA bundle, the CA cert, the passwd file and the
generated profile. A sandbox can overwrite a concurrent session's material.
Deny those name patterns after the rwDirs and roDirs allows so no user config
can re-grant them, then re-allow this session's own HOME.

`roDirs` and `roFiles` nested inside a read-write path stay writable on macOS,
because seatbelt is last-match-wins and the read-only rules are emitted first.

Plus the full nested-bind resolution deferred from S2.

Each of these has an issue filed. Close them from here.

Acceptance: the suite passes, plus one regression test per finding.

## Totals

Around 20 to 22 human-days across 12 PRs, of which S1 and S2 are roughly 2 and
ship first, before any restructure work starts.

Units 0 through 3 are around 5.5 days and deliver the reviewability win on their
own, which matters while PRs are arriving. Units 5 and 6 are half the remaining
effort and carry most of the risk.

## Decisions still open

These are needed before the units that depend on them, not now.

How to pin the fixtures' nixpkgs (unit 2): a shared file deriving the revision
from `flake.lock`, a `--arg pkgs` threaded from `run-all.sh`, or a pinned
`fetchTarball` in each fixture.

Whether the unit tier uses bats or extends `tests/lib.sh` (unit 7).

Whether `lib/shared.nix` still wants splitting once its bash has moved out
(after unit 4).

## Names to confirm

Proposed, not adopted. Nothing below is used anywhere yet. Units 4, 5 and 6
each add their rename list here for confirmation before applying it.

- The logic files: `lib/linux/wrapper.sh`, `lib/darwin/wrapper.sh`,
  `lib/shared/*.sh`. Mirrors the existing `lib/pre-entry-script.sh` precedent.
- The prelude's tool constants: `GIT_BIN`, `FIND_BIN`, `PROXY_BIN` and so on.
  Suffix distinguishes a store path to an executable from a plain path.
- The dump mode's trigger, currently written as "spec dump" throughout: needs a
  real name and an env var, kept distinct from `AGENT_SANDBOX_LOG_DIR` so the
  test facility is not confused with the user-facing artifact.
- `tests/golden/` for the checked-in files, and a name for the regenerate
  command.

## Deferred

- A version string in `startup.log` for issue triage. There is no version in the
  Nix source today, only tags and `CHANGELOG.md`, so it needs its own change.
- Moving user `env` off the command line into the args file, if the shared-host
  `/proc/<pid>/cmdline` exposure turns out to matter. The run directory copy
  becomes a redacted rendering rather than the launch input if so.
- Proxy allow-side URL logging, with its own opt-in.
- Moving the macOS indexed seatbelt params to runtime profile appends, which
  would let `rwDirs` and friends vary without a rebuild. Note this is a capability
  change, not a refactor, and the reasons not to want it are separate.
