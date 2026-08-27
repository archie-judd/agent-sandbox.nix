# Port the launcher to Python

The wrapper script has no source file. It exists only as the concatenation of
around twenty Nix-interpolated fragments spliced into one flat top-level scope,
communicating through globals defined in other files. Reading the macOS launch
means knowing that `ancestorTraversalBashStr` sets `ANCESTOR_DIRS`, that
`ancestorProfilePatchBashStr` consumes it and sets `SANDBOX_PROFILE`, that
`gitProtectionProfilePatchBashStr` consumes that plus `GIT_PROTECTED_DIRS` from
`lib/shared.nix`, and that `networkRuntimePatchBashStr` in
`lib/darwin/networking.nix` also appends to `SANDBOX_PROFILE` and depends on
`_PROXY_PORT` set back in `lib/shared.nix`. Five files, four implicit globals,
one ordering constraint enforced nowhere. The header comment in
`lib/linux/symlink-helpers.nix` documents that constraint in prose because
nothing else can.

Consequences: no shellcheck, since the code is Nix strings. No unit tests, since
the functions cannot be called without building and launching a sandbox. Review
means reading a diff of a string embedded in a Nix expression.

The fix is not better bash. It is to stop generating a program and start
configuring one.

## Target architecture

Nix emits a JSON spec at build time. A Python program reads it at launch time,
reads the host, computes the sandbox configuration, and writes it into a session
directory. A small bash stub launches the sandbox.

```
build (nix)     validate args, writeClosure, emit spec.json, emit env fragment

launch          stub.sh
                  agent-sandbox prepare spec.json  ->  prints session dir
                    read host state, check launch allowed,
                      create session state, compute sandbox config,
                        write artifacts
                  trap agent-sandbox cleanup <session dir> on EXIT
                  run the sandbox in the foreground
```

Three properties make this work where the current design does not.

The spec is data, so string context stops being a hazard. `builtins.readFile`
returns a context-free string, which is why a `.sh` file cannot hold a store path
and why any move to real source files needs a hand-maintained data prelude. A
spec built with `builtins.toJSON` carries its context, so store paths are just
values.

The decision layer is pure. `compute_launch_config(spec, host_state,
session_state)` returns the argv segments, the artifact bodies and the
warnings. It reads no files, runs no subprocesses and prints nothing.

Reading the host is a separate step, so the git protected-path enumeration and
the symlink chain walks happen before it and arrive as data. What stays in the
pure layer is every decision: which targets a bound prefix already covers,
which symlink hops get bound and which get refused, which parent directories
bubblewrap needs, and the order of the seatbelt rules. That is exactly the code
that is currently untestable without launching a sandbox.

Nix keeps deciding what enters the closure. `sandbox-proxy` is referenced only
from the restricted branch today, so an unrestricted wrapper does not carry the
Go proxy in its closure. The spec preserves that by emitting the proxy path only
when `allowedDomains` is set, with Python branching on whether the key is
present. Python branching on the key preserves it; Python deciding it would not.

### What stays where

Nix keeps eval-time argument validation. `validateAllowedLocalPorts` and
`assertNoLegacyArgs` throw when the shell is built, not when the agent is
launched. Moving them into Python would turn a build error into a runtime one,
which is a regression.

Nix keeps `writeClosure`. Python reads the resulting file, which is already how
the Linux side works.

Bash keeps the launch and the EXIT trap. Signal handling, foreground process
group behaviour and tty passthrough are the boring things a rewrite gets subtly
wrong, and bash already does them. The stub does not `exec`: replacing the shell
is what stops the trap firing, which is the bug unit 0 fixed on macOS. It runs
the sandbox in the foreground and calls `agent-sandbox cleanup` on exit, so the
conditional cleanup stays in Python.

The stub carries no logic and no build-time branching. It holds one variable,
reads fixed filenames from the session directory and assembles one command line.
It is a real `.sh` source file with two `substituteAll` placeholders, the
interpreter and the spec, so it is byte-identical for every build on both
platforms and shellcheck can see it.

Bash also keeps `env` expansion. See Behaviour changes below.

The Go proxy is untouched. It is self-contained, it has its own tests, and it is
the one component where Go is unambiguously the right choice.

### Directory layout

```
default.nix
flake.nix
pyproject.toml            tool config only: mypy, later pytest
lib/
  default.nix             mkSandbox, validation, writeClosure
  spec.nix                emits spec.json
  stub.sh                 what $out/bin/<outName> is
  pre-entry-script.sh     first process inside the sandbox
launcher/                 the python, imported as `launcher`
proxy/                    go, unchanged
tests/
```

Four directories, each holding one artifact. The build-time and launch-time
distinction is the spine of this design, but it is not in the tree: a `build/`
directory would have held the Nix and a `launch/` directory everything else, and
a directory whose job is to hold one sibling groups nothing. `build/` is also
the setuptools output directory and conventionally gitignored, which is a poor
name to track next to a `pyproject.toml`.

The two shell scripts sit in `lib/` because they are build inputs rather than
free-standing programs: one is read with `builtins.readFile`, the other has
`substituteAll` applied to it, and both are consumed by derivations defined
beside them.

Inside the package, one module per type family, named for the type it owns:

```
launcher/
  __init__.py              empty, deliberately
  constants.py             artifact filenames, retention, deadlines, listen address
  build_spec.py            SandboxBuildSpec, Dependencies, ProxySpec
  host_state.py            HostState, DeclaredPath / File / Dir, GitState
  session_state.py         SessionState, ProxyState
  launch_checks.py         get_launch_refusals, and the only prompt in the program
  launch_config/
    shared.py              SandboxLaunchConfig, get_usable_git_state
    write.py               write_launch_config, the only file-format knowledge
    linux.py               SandboxLaunchConfigLinux, compute_launch_config
    darwin.py              SandboxLaunchConfigDarwin, compute_launch_config
    seatbelt.py            static profile sections, data only
  prepare.py               entry point
  cleanup.py               entry point
  apply_network_rules.py   entry point, Linux, runs inside pasta's namespace
```

`launch_config/` is a package while `host_state.py` and `session_state.py` are
single files because the split follows the size of the divergence rather than
its presence. All three have platform variants, but `SessionStateLinux` adds no
fields and `HostStateLinux` adds two, whereas the two `compute_launch_config`
implementations share almost nothing and carry the entire bubblewrap and
seatbelt ordering between them.

`launch_checks.py` stays separate from `host_state.py` because folding it in
would put policy inside the observation module, which is the boundary the whole
design rests on.

`write_launch_config` ended up in its own module rather than in `shared.py`,
because it has to see both platform configurations and both of those import the
base from `shared`, so putting the writer there makes the imports circular.
`shared.py` holds the base dataclass and `get_usable_git_state`, the one
decision both platforms make identically.

### Python constraints

Standard library only. No pydantic. The spec is machine-generated by our own Nix
code from arguments Nix already validated, so it is not untrusted input, and
`json.load` plus a frozen dataclass constructor gives the same guarantees for
the failures that can actually occur. Pydantic's import cost, typically 50 to
120 ms, would also consume the entire startup budget on its own.

That budget, measured on an M-series mac: bash starts in 9 ms, Python in 16 ms,
Python plus json, os, pathlib, subprocess and shutil in 33 ms. Against that, one
`dirname` fork costs 2.6 ms and one `git rev-parse` costs 7.5 ms. The built
wrapper has thirteen static `dirname` sites, several inside loops, and the macOS
ancestor walk runs one per path component per declared path. Doing that work
in-process should make the Python launcher faster than the bash one, not slower.
If a change pushes interpreter plus imports past about 40 ms, that reasoning has
stopped holding and wants rechecking.

Frozen dataclasses only, with `__post_init__` for validation. Everything else is
a function or a primitive. No mutable module-level state. Module-level constants
are fine.

mypy strict, fully annotated. pyright is in the devshell as well and is the
faster loop while writing; mypy is what `pyproject.toml` configures and what
CI should gate on.

No nested functions. A function defined inside another closes over its enclosing
locals, which is the same invisible-scope problem the whole port exists to
remove: you cannot tell what it depends on from its signature, and you cannot
call it from a test. Lifting one out means passing what it needs as arguments,
which is the point.

Internal functions are prefixed with `_`, exported ones are not. The prefix is
what says a name is not part of the module's surface, so it has to be accurate:
a helper used only by its own module gets one even when a test reaches in for
it.

Explicit keyword arguments rather than `**` splatting, with one exception: a
`TypedDict`. mypy validates the unpacked keys against the constructor being
called when the source is typed, and cannot when it is a plain dict, so the
splat stays as checkable as writing the arguments out. That is what
`_CommonHostState` is for, and the cost it pays is duplicating the shared field
list once.

`Path` rather than `str` wherever the value is a real path. The one exception is
declared paths before expansion, which carry `$VAR` and `~` and so are not paths
yet; they become `Path` in `host_state`, and the type changing at that boundary
is what makes it impossible to stat an unexpanded path by accident.

Not packaged at all. Nix copies the source tree into the store and the stub
points `PYTHONPATH` at it. `buildPythonApplication` was rejected because it
emits a bash wrapper per console script that runs on every launch in front of
every entry point; `buildPythonPackage` was rejected because it wants a
`pyproject.toml` and a build backend for a stdlib-only tree with no
dependencies, and forces the package into a source root of its own. mypy and
pytest get a check derivation in unit 4, configured from the repo-root
`pyproject.toml`.

The stub sets `PYTHONPATH` inline and invokes `python3 -P -s -S -m
launcher.<entry>`. Not `-I`: isolated mode implies `-E`, which makes the
interpreter ignore `PYTHONPATH`, so the package would not be importable. `-P`
keeps cwd and the script directory off `sys.path`, `-s` drops the user site
directory, and `-S` skips `site` entirely, which is also where a chunk of the
startup cost lives. The residual exposure is a user with `PYTHONHOME` set, which
breaks loudly rather than silently.

`launcher/__init__.py` stays empty. The in-namespace network entry point runs on
the Linux hot path and needs only `os` and `sys`, so it pays a bare interpreter
start of around 16 ms rather than the 33 ms the full import set costs. Any
re-export added to `__init__.py` would silently hand it the whole package.

### Nix constraints

No `inherit` and no `with`. Write attribute bindings out explicitly, so
`{ pkgs = pkgs; shared = shared; }` rather than `{ inherit pkgs shared; }`. Both
forms make the origin of a name invisible at the point of use, which is the
ambient-scope problem this port is removing from the bash; explicit bindings
also survive grep.

Nix keeps camelCase. The JSON it emits does not, because that is a wire format
read by Python rather than Nix source.

### Naming

Settled:

| Name | Meaning |
|---|---|
| `SandboxBuildSpec` | the JSON Nix emits at build time |
| `HostState` | what reading the host returns |
| `SessionState` | what the launcher creates for this launch |
| `SandboxLaunchConfig` | the pure result: argv segments, artifact bodies, warnings |
| `read_host_state` | observes, decides nothing |
| `get_launch_refusals` | every reason to refuse; empty means allowed |
| `create_session_dir` | the directory, before anything can refuse |
| `create_session_state` | the proxy and the sandbox home |
| `compute_launch_config` | the pure decision layer |
| `write_launch_config` | the only step that knows a file format |
| `prepare_launch`, `cleanup_launch` | the two entry points |

The CLI verbs are `prepare` and `cleanup`, short, with the long names kept for
the Python functions.

Platform variants take a suffix: `SandboxBuildSpecLinux`, `DependenciesDarwin`,
`HostStateLinux`, `SessionStateDarwin`, `SandboxLaunchConfigLinux`. Suffix rather than
prefix so each variant sorts next to its base in an import list and in an
editor's symbol outline.

camelCase in Nix, snake_case in Python, and snake_case in the JSON keys too. The
spec is a wire format between the two rather than Nix source, and a per-field
name mapping is one more thing that can drift.

The per-launch directory is called the session directory rather than the state
directory, because `stateDirs` was just deprecated in favour of `rwDirs` and
reusing "state" for an unrelated concept makes both harder to search for. Not
the config directory either, because it holds a pid, a cleanup list and a log
alongside the computed configuration.

`HostState` and `SessionState` are separate because they differ in kind.
`HostState` is observed: the cwd, the git common dir, the real home, the tty,
the nix daemon socket, the resolved symlink chains. It is read-only, and its
members can legitimately be absent, since there may be no repository and no tty.
`SessionState` is established: the session directory, the sandbox home on macOS,
and the proxy port and pid. Its members always exist once the step has run.

`SessionState` is not the cleanup list. The session directory survives the run
on purpose, and so does everything sitting at a fixed name inside it. What
cleanup removes is the sandbox home, the proxy process, and the empty mount
points bubblewrap materialises for git protected files that did not exist at
launch.

`SessionState` is established before the configuration is computed, not after.
Its paths appear inside the computed profile and the computed argv, so the order
in the diagram above is load-bearing: create the paths, compute against them,
then write what compute returned.

## Behaviour changes

Six, all needing release notes. Two have already shipped as security fixes.

`env` values keep shell semantics. `templates/claude/flake.nix:36-42` and the
README document `env` values as runtime shell expressions, both the
`"$CLAUDE_CODE_OAUTH_TOKEN"` form and the sops
`"$(cat /run/secrets/...)"` form. That is deliberate, so tokens stay out of the
store. Python cannot reproduce it: `expandvars` does not do command
substitution, and shelling out per value reintroduces the shell one layer down.
So Nix emits one data line per declared variable into a fragment the stub
sources, and the token never enters Python. This is the one honest use of a
generated bash fragment left in the design: no logic, one line per variable.

Declared paths lose shell semantics. `rwDirs = [ "$HOME/.claude" ]` works today
only because the path string is interpolated into bash and the shell expands it,
which means `rwDirs = [ "$(...)" ]` currently executes. Paths move into the spec
and get explicit `$VAR`, `${VAR}` and `~` expansion in Python, with no command
substitution. Env keeps the shell because it is documented; paths lose it
because nobody asked for it.

An undefined variable in a declared path is fatal. The shell expands it to
empty, so `rwDirs = [ "$TYPO/.claude" ]` currently builds, launches, and fails
the existence check with a message naming `/.claude`. Python refuses at launch
and names the variable. This is a consequence of the change above rather than a
separate decision, but it is separately visible.

A declared path that expands to a relative path is fatal. The shell passed the
raw string to bubblewrap, which resolved it against its own working directory,
so `rwDirs = [ "somedir" ]` bound a different folder depending on where the
wrapper was run from. It is refused at launch instead, which also catches
`rwDirs = [ "$(...)" ]`: with no command substitution the text survives
literally, and literal text is not an absolute path.

Nested binds refuse at launch. Shipped in S2.

Loopback and link-local resolutions are refused by the proxy. Shipped in S1.

## Secrets

`env` values never touch disk. Both platforms pass them as `K=V` arguments to
`env -i`, so no artifact and no part of the profile holds them, and the session
directory is verbatim and publishable. Linux drops bubblewrap's `--clearenv` and
`--setenv` to get there, which also moves the values off the sandboxed process's
`/proc/<pid>/cmdline`, readable by any user on the host, and into
`/proc/<pid>/environ`, readable only by its owner. Nothing needs redacting,
which is better than redacting correctly.

One qualification, since the sentence above used to claim more than the code
does. The values are arguments to `env`, so they are on `env`'s own cmdline for
as long as that process lives, which is the microseconds before it execs. They
are off the cmdline of everything that runs afterwards, which is the whole
session. That is strictly better than the `--setenv` it replaced, where they sat
on bubblewrap's cmdline for the entire run, but it is not absolute and a local
attacker polling `/proc` could win the race.

`launch.log` records env keys without values, from the keys-only list the spec
already carries. Building that list in Nix from the same attrset means it cannot
be defeated by a value that looks like a flag, and the launcher could not write a
value if it tried: they are resolved by the stub and never enter Python.

The session directory must stay safe to attach to a GitHub issue. That is the
property the debug logging design is built around, and it is why proxy
allow-side URL logging stays out of scope.

Three files in the session directory are read by the sandboxed process: the CA
bundle via `SSL_CERT_FILE`, the CA certificate via `NODE_EXTRA_CA_CERTS`, and
the passwd file, if the passwd file turns out to have a reader on macOS at all
(see unit 2). Grant those three by name, not the directory by subpath. Granting the subpath would also hand over
`proxy.pid`, and `lib/darwin/seatbelt-profile.nix:45-49` deliberately denies
`kern.proc.*` and `kern.procargs2` so the sandbox cannot enumerate host
processes, while line 28 grants `(allow signal)` and macOS has no PID namespace.
A readable pid file reconstructs by hand the thing those denies exist to
prevent. Per-file rules also match what Linux does anyway, where each is already
bound individually and remapped to a fixed path.

## Session directory

One directory per launch, replacing both the debug-artifact design and the
manifest that would otherwise pass between Python and bash.

```
<root>/<timestamp>-<pid>-<outName>/
  argv-before-env   NUL-separated
  argv-after-env    NUL-separated
  bwrap.args        Linux, newline-separated, for reading only. See unit 2.
  network.json      Linux: the nft ruleset, the sysctls, the route decision
  seatbelt.sb       macOS
  seccomp.bpf       Linux, the compiled AF_UNIX denial, unless allowUnixSockets
  launch.log        what was requested, what was decided, how it ended
  passwd
  ca-bundle.pem     restricted mode only
  ca-cert.pem       restricted mode only
  proxy.pid         restricted mode only
  proxy.log         restricted mode only
  stub.pid          written by the stub, read by a later launch's prune
  cleanup           NUL-separated paths to remove on exit
  cleanup-if-empty  NUL-separated, removed only if still empty
```

`nft.rules` became `network.json` because the in-namespace entry point applies
three kinds of thing, not one: the ruleset, the `/proc/sys` writes a ruleset
cannot express, and whether to drop the default route. JSON because a boolean
does not belong in a file of nft syntax. `cleanup-if-empty` is separate from
`cleanup` because bubblewrap materialises a mount point on the host for a git
protected file that did not exist at launch, and that has to go, but not if
something has written real content there in the meantime.

Everything except the sandbox home sits here at a fixed name. That is what lets
the stub read what it needs without being told, and what keeps `SessionState`
down to a directory, a proxy port and a pid. The sandbox home stays under
`/private/tmp` on macOS: moving it here would put it under the real home, which
changes what `(allow file-read* process-exec (subpath (param "HOME")))` grants.

Everything something re-splits is NUL-separated: both argv files and both
cleanup lists, because a path may contain a newline. `bwrap.args` is not one of
them. Nothing parses it, bubblewrap gets those arguments inline, and its only
reader is a person, for whom NUL makes the file one run-on line; it is
newline-separated so it can be read, and `argv-after-env` remains the copy that
has to be unambiguous.

Root resolution: `AGENT_SANDBOX_SESSIONS_ROOT`, else `$XDG_STATE_HOME`, else
`$HOME/.local/state`. Timestamp leads the name so `ls` sorts chronologically and
pruning by name matches pruning by mtime. `outName` is in the name because
several wrappers share one root.

The override is deliberately undocumented, which is also what settled its name.
`XDG_STATE_HOME` is the knob a user already has and it is honoured, so a second
documented one would be a compatibility promise bought for a case the convention
already covers; the suite needs the variable to point launches at a scratch
root, so it exists. Undocumented means the name only has to be right for
contributors, and `AGENT_SANDBOX_LOG_DIR` had stopped being right once the
directory held the computed configuration as well.

Created first thing, ahead of the bind-existence check, so a run refused for a
missing bind or a declined home-directory launch still records why.

The wrapper prints nothing about the directory on a successful launch, and names
it when it refuses one, which is the moment there is a reason to look. The rest
of discoverability is the README's job.

Unit 2 creates the directory and writes the artifacts. The launch log and the
warning when a declared path covers the root are unit 3, which adds behaviour to
a directory that already exists rather than relocating anything.

Retention came forward out of unit 3 and shipped with the port, because leaving
it out meant releasing unbounded accumulation one release after unit 0 fixed
unbounded accumulation. The prune skips any session whose `stub.pid` is still
alive, checked with signal 0, which delivers nothing. Without that it could
delete a directory a running sandbox is still reading: `SSL_CERT_FILE` points
into the session directory on macOS, and `cleanup` reads the proxy pid and both
removal lists off disk on both platforms. Pid reuse can only make a finished
session look live, so the error falls on the side of keeping a directory.

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
unit 5. It is far cheaper written against the restructured code.

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

## AF_UNIX sockets

Done in dbca506, behind an `allowUnixSockets` flag defaulting to false. It was
deferred until after the port and landed straight after it, because computing
the seatbelt profile and the bubblewrap arguments in Python is what made both
halves cheap.

A boolean rather than a list of directories, for the reason recorded when it was
deferred: macOS can express any path scope with `subpath` rules, while Linux has
two positions and no third, since classic BPF cannot dereference the
`sockaddr_un`. A path list would have been enforced on macOS and unenforceable
on Linux.

On macOS the profile allows `network-bind` and `network-outbound` scoped by
subpath to the working directory and the declared read-write directories,
connect alone at the read-only paths and at the repository root, and denies bind
again at read-only paths nested inside a read-write one. The rules are assembled
after the network section so they outrank open mode's blanket
`(deny network-outbound (remote unix-socket))` by last-match. `/tmp` stays out
of scope deliberately, since per-user launchd listeners live there. The
repository root is granted connect because it is visible on both platforms but
declared by nobody, so a build server keeping its rendezvous socket there worked
on Linux and failed on macOS, which is the platform-dependent failure this
feature exists to remove.

`(local unix-socket (subpath ...))` was the unverified fact. The SBPL compiler
accepts it, so the macOS half needed no different shape.

On Linux the flag being off is now enforced rather than assumed: a classic-BPF
filter fails `socket(AF_UNIX, ...)` with EPERM, while `socketpair(2)` is a
different syscall and passes untouched. EPERM rather than a kill, because
callers probe for AF_UNIX services and fall back, and killing turns each probe
into a crash. The program is computed at launch rather than built by Nix, so it
lands in the session directory with the other artifacts and a denied `bind()`
can be debugged by reading what was loaded; it depends on the machine's audit
arch and syscall numbering, and a machine outside that table refuses the launch.
The descriptor `--seccomp` needs is opened in the network entry point, the
placement rejected for bubblewrap's own arguments under unit 2. There it was a
choice; here nothing else survives pasta.

The open decision is settled the strict way: `allowNix` requires
`allowUnixSockets`, as an eval-time error on both platforms rather than an
implication on Linux, so a configuration that builds on one platform builds on
the other.

## Units

Each unit is one PR. Day estimates are rough.

### 0. Fix the macOS EXIT trap

Done in af4b305. 2 files.

`lib/darwin/networking.nix` set `sandboxExecBashStr = "exec "` in the
unrestricted branch, so the shell is replaced and the EXIT trap set by
`bashTrapCleanupStr` never fires. On the default macOS config, with no
`allowedDomains`, nothing is cleaned up: `$SANDBOX_HOME`, `$SANDBOX_PROFILE` and
`$_SANDBOX_PASSWD` all survive every run. There were 165 of each left on the
development machine.

This breaks a documented promise. On Linux `$HOME` is a real tmpfs and
disappears structurally; on macOS the `rm -rf` is the only thing making it
ephemeral.

Fix: drop `exec ` so both branches keep the wrapper shell as parent, which is
what the restricted branch already did.

Shipped first and alone, so it can be backported. Unit 2 fixes it structurally,
in that the stub never execs.

Acceptance: the suite passes, plus a new test that no
`/private/tmp/sandbox-home.*` survives an unrestricted run.

### 1. Test housekeeping

Done in 65167a3. Around 25 files, almost all mechanical.

Three unrelated fixes, batched because they all touch the suite and none is
worth its own PR.

Pin the fixtures' nixpkgs. 21 of the 22 files in `tests/fixtures/` do
`pkgs = import <nixpkgs> { }`, which is the ambient channel, not the flake's
pinned `nixos-unstable`, and nothing in `tests/` or `.github/workflows/test.yml`
sets `NIX_PATH`. The suite builds against whatever nixpkgs is on the machine, so
a CI failure need not reproduce locally.

Make the harness contract explicit. `tests/lib.sh` calls a `run()` function that
each test file defines as an undeclared global hook, and `expect_ok` invokes it
as `run "$*"`, flattening arguments into one string so quoting is silently
lossy. A test file can redefine `run` halfway down to switch which sandbox it
asserts against, invisibly in review. Same ambient-contract problem as the
wrapper, same fix.

Hoist the builds. Each test file runs its own `nix-build`, so evaluation happens
around thirty times per suite. Build once in `tests/run-all.sh` and pass paths
down.

Acceptance: the suite passes, and passes identically on a machine whose ambient
`<nixpkgs>` differs from the pin. Nothing under `lib/` changes.

### 2. The port

Done. macOS cut over in 0a198da, Linux in 2963454, with four fixes between them.
The `build/` and `launch/` directories were dropped on the way, for the reason
under Directory layout above.

Both backends in one pass. `lib/shared.nix` feeds both, so splitting Linux and
macOS into separate PRs means porting the git protected-path enumeration twice
or shipping a half-Nix half-Python seam.

`proxy/` stays where it is and the Go is untouched.

The steps.

```
prepare_launch(spec_path) -> session dir
  spec        = load_build_spec(spec_path)
  session_dir = create_session_dir(spec)
  host        = read_host_state(spec)
                get_launch_refusals(spec, host)
  session     = create_session_state(spec, host, session_dir)
  config      = compute_launch_config(spec, host, session)
                write_launch_config(config, session)
```

`get_launch_refusals` returns every reason the launch must not proceed rather
than the first, so a run with three typo'd paths reports all three. It is the
one place in the launcher that prompts, since launching from the real home has
to be confirmed by a human, and `prepare_launch` owns the exit.

`create_session_dir` is separate from `create_session_state` so the directory
exists before anything can refuse the launch, without a proxy having been
started for a run that is about to be refused.

Every path the launcher hands on is physical, in `HostState` and in
`SessionState` alike: parent directories resolved to their fully-followed form,
with the final component left alone. Two names for the same directory never
compare equal as strings, and `/tmp` being a symlink to `/private/tmp` on macOS
is enough to break a comparison silently. Four separate defects came from this:
the launch-from-home confirmation never fired, the macOS nested-bind guard
skipped every check, symlink chain hops would have become seatbelt rules
matching nothing, and the session directory stayed logical so the rule granting
the sandbox its own passwd file matched nothing either. The first three were
found by reasoning; the fourth only by building a real wrapper and reading the
profile it produced. The final component keeps its own
name because whether a declared path is itself a symlink decides how it is
bound.

The rule is not free, and unit 2 ships with one known cost: applied to symlink
chain hops it resolves away symlinked directories that bubblewrap still needs.
See the Linux gap noted under unit 2 below.

`read_host_state` may read files, run git and resolve symlinks. It may not
create, delete, prompt or decide. `get_launch_refusals` holds the
bind-existence check, the home-directory confirmation and, on macOS only, the
nested-bind refusal; all are pure predicates over `HostState` except the
confirmation, which needs `/dev/tty`.

The git-root-is-home rule is not among them. It does not refuse a launch, it
disables git for the session and warns, so a function whose contract is refuse
or continue cannot express it. It is a decision about what to bind, so it lives
in `compute_launch_config` with the other bind decisions, and its warning goes
into `SandboxLaunchConfig.warnings`.
`create_session_state` is the only step that creates anything.
`compute_launch_config` is pure. `write_launch_config` is the only step that
knows a file format.

The rule that decides which side a fact belongs on: if it can be stated without
naming bubblewrap, seatbelt, binds or rules, it is an observation and belongs in
`HostState`; otherwise it is a decision and belongs in `compute_launch_config`.
So "`/etc/resolv.conf` names a loopback nameserver" is observed, and "use
`/run/systemd/resolve/resolv.conf` instead" is decided. The rule is checkable
field by field, which is the point of having one.

It costs one piece of wasted work, deliberately. Refusing git when the repo root
is `$HOME` is a decision, so it fires after the protected-path enumeration has
already run, and on a home-rooted repo that is one `find` and two `git config`
calls whose results are discarded. Letting the observation step consult the
policy would remove the only thing that makes the split verifiable by reading
signatures.

Two consequences. The warnings `_add_symlink_target` prints to stderr today
become `SandboxLaunchConfig.warnings`, printed by `write_launch_config`, which makes
them assertable. And the passwd file's path is session state while its content
is a pure function of uid, gid and the real home, so it is computed like every
other artifact rather than written by the step that creates the directory.

The nested-bind check gets simpler on the way. `lib/darwin/default.nix:281`
walks the real filesystem under `$SANDBOX_HOME` because bash has nowhere else to
hold the set of planted paths. Whether one declared path nests inside another is
answerable from the expanded declared list alone, with no filesystem access.

The types. Platform variants take a suffix and share a base; the `platform`
literal is declared on the subclasses, not the base, so mypy has a tagged union
to narrow on.

```python
@dataclass(frozen=True)
class SandboxBuildSpec:
    out_name: str
    sandbox_path: str                 # PATH inside the sandbox
    allow_nix: bool
    rw_dirs: tuple[str, ...]          # unexpanded, as written in Nix
    rw_files: tuple[str, ...]
    ro_dirs: tuple[str, ...]
    ro_files: tuple[str, ...]
    env_keys: tuple[str, ...]         # keys only; values never enter Python
    allowed_local_ports: tuple[int, ...] | None
    closure_paths_file: Path
    cacert_dir: Path
    cacert_bundle: Path
    shell: Path                       # bashWrapper/bin/bash
    pre_entry_script: Path
    sandboxed_binary: Path            # <pkg>/bin/<binName>
    proxy: ProxySpec | None

class SandboxBuildSpecLinux(SandboxBuildSpec):
    platform: Literal["linux"]
    hosts_file: Path
    empty_file: Path
    dependencies: DependenciesLinux

class SandboxBuildSpecDarwin(SandboxBuildSpec):
    platform: Literal["darwin"]
    dependencies: DependenciesDarwin
```

`Dependencies` means host binaries the launcher executes, as opposed to store
paths bound into or referenced from inside the sandbox. It is small because the
port deletes most of it: `dirname`, `readlink`, `realpath` and `find` all become
in-process calls.

```python
class DependenciesLinux:
    git: Path
    bwrap: Path
    pasta: Path
    nft: Path
    ip: Path
    env: Path        # coreutils; `env -i`, and the /usr/bin/env symlink target

class DependenciesDarwin:
    git: Path        # sandbox-exec and env are /usr/bin, so constants

class ProxySpec:
    binary: Path
    allowlist_file: Path
    redirects: Mapping[str, str] | None = None   # test harness only
```

`ProxySpec` is the one nested type in the spec, because its three fields are
present or absent together and that invariant is the closure property: no
`allowedDomains`, no reference to the Go proxy anywhere in the emitted JSON.
`redirects` is absent from the key set entirely in a production build, so the
test seam leaves no trace. The listen address is `127.0.0.1` at both call sites
today and never varies, so it is a Python constant, as is the proxy startup
deadline.

```python
class Symlink:                        # a symlink on the host
    path: Path
    points_to: Path                   # what it says, not where it ends up

class SymlinkHop:                     # one link, followed once
    points_to: Path                   # physical
    parent_symlinks: tuple[Symlink, ...]

class SymlinkChain:
    hops: tuple[SymlinkHop, ...]      # empty when the path is not a symlink

class DeclaredPath:
    unexpanded_path: str              # "$HOME/.claude", for diagnostics
    expanded_path: Path
    mode: Literal["rw", "ro"]
    exists: bool
    symlink_chain: SymlinkChain
    parent_symlinks: tuple[Symlink, ...]

class DeclaredFile(DeclaredPath): ...
class DeclaredDir(DeclaredPath):
    inner_symlinks: tuple[SymlinkChain, ...]

class GitState:
    common_dir: Path
    repo_root: Path
    protected_dirs: tuple[Path, ...]
    protected_files: tuple[Path, ...]

class HostState:
    cwd: Path
    real_home: Path
    uid: int
    gid: int
    term: str | None
    has_controlling_terminal: bool
    declared: tuple[DeclaredPath, ...]     # declaration order preserved
    git: GitState | None
    closure_paths: tuple[Path, ...]
    nix_daemon_socket: Path | None

class HostStateLinux(HostState):
    resolv_conf_names_loopback: bool
    systemd_resolv_conf: Path | None

class HostStateDarwin(HostState):
    tty: Path | None
```

Splitting `DeclaredPath` by kind rather than by symlink-ness is deliberate:
`inner_symlinks` varies with being a directory, not with being a symlink, and a
declared file never has any. `is_symlink` is absent because `symlink_chain` is
non-empty exactly when the path is one, and keeping both is redundant state with
a way to disagree.

```python
class ProxyState:
    port: int
    pid: int

class SessionState:
    session_dir: Path
    proxy: ProxyState | None

class SessionStateLinux(SessionState): ...
class SessionStateDarwin(SessionState):
    sandbox_home: Path

class SandboxLaunchConfig:
    argv_before_env: tuple[str, ...]
    argv_after_env: tuple[str, ...]
    passwd: str
    cleanup: tuple[Path, ...]
    warnings: tuple[str, ...]

class SandboxLaunchConfigLinux(SandboxLaunchConfig):
    bwrap_args: tuple[str, ...]
    network: NetworkConfig

class SandboxLaunchConfigDarwin(SandboxLaunchConfig):
    seatbelt_profile_lines: tuple[str, ...]
```

The artifacts stay sequences through `compute_launch_config` and only meet a
separator in `write_launch_config`. Flattening them earlier would throw away the
structure that keeps a path with a space in it one argument, and would reduce the
unit tier to string matching. What the tests need to be able to write is that
`("--bind", "/tmp/a b", "/tmp/a b")` appears in `bwrap_args`, and that a deny
line's index exceeds an allow line's index in `seatbelt_profile_lines`, since
seatbelt is last-match-wins.

The launch line. Both platforms have the same shape, and the two computed
segments exist for exactly one reason, which is that the declared env values
have to be injected between them without passing through Python.

```
argv_before_env   Linux  pasta ... -- <namespace entry> network.json
                         env -i <computed K=V>
                  macOS  env -i <computed K=V>

<declared K=V>           from the Nix env fragment, sourced by the stub

argv_after_env    Linux  bwrap <computed args>  pre-entry  sandboxed-binary
                  macOS  sandbox-exec -f seatbelt.sb  pre-entry  sandboxed-binary

"$@"                     the stub's own arguments
```

Declared env comes last of the two K=V groups, so a user-declared `HOME` or
`PATH` still overrides the computed one, which is what both backends do today.
Reversing that would make the sandbox's own environment unoverridable and is a
behaviour change this unit deliberately does not make.

Linux drops `--clearenv` and `--setenv` so both platforms use the `K=V` form and
the Nix env fragment has one shape. Bubblewrap without `--clearenv` passes its
own environment through, so `env -i K=V ... bwrap` reaches the same end state.

The stub, in full, byte-identical for every build and with no conditional left
in it:

```bash
SESSION_DIR=$("@python@" -P -s -S -m launcher.prepare "@spec@") || exit 1
trap '"@python@" -P -s -S -m launcher.cleanup "$SESSION_DIR"' EXIT
source "@envFragment@"                         # sets DECLARED_ENV=( K=V ... )
mapfile -d "" ARGV_BEFORE_ENV < "$SESSION_DIR/argv-before-env"
mapfile -d "" ARGV_AFTER_ENV  < "$SESSION_DIR/argv-after-env"
"${ARGV_BEFORE_ENV[@]}" "${DECLARED_ENV[@]}" "${ARGV_AFTER_ENV[@]}" "$@"
```

It had a sixth line, `exec 3< "$SESSION_DIR/bwrap.args"`, so that bubblewrap
could read its arguments from a descriptor with `--args 3`. That does not work,
and the reasoning that put it there was wrong twice over. See the fd 3 note
below.

What collapses. The five `mkResolve*BashStr` generators and `mkScanDirBashStr`
in `lib/linux/symlink-helpers.nix` become loops. The four
`mkSymlinkHomeMappingStr` call sites, the four traversal blocks in
`ancestorTraversalBashStr` and the eight `resolve*Str` and `*Flags` generators
in `lib/darwin/default.nix` become one loop each. The two parallel attrsets in
each `networking.nix`, with their matching key sets, become one code path with
conditional data.

What disappears entirely. Every `-D` param on macOS, along with
`seatbelt-profile.nix`'s `(param "X")` indirection, the `STATE_DIR_0` through
`STATE_DIR_N` index-name generators, and the `/nonexistent-git-dir` and
`/nonexistent-tty` sentinels that exist only because a param reference must
resolve to something. Seatbelt params are string-only, which is why
variable-length lists had to be appended at runtime; computing the whole profile
in Python removes the constraint, and `lib/darwin/seatbelt-profile.nix` goes with
it, its 210 lines becoming ordered section constants. Also gone: the FIFO, the
`exec 3<>` read-write trick and the `( sleep 5 && kill $$ ) &` timeout in
`mkProxyStartupBashStr`, which become a `Popen` and a readline with a deadline.
The deadline has to tell a slow start from a dead child by polling the process,
which the bash timeout could not do.

The port keeps flowing from the proxy to the launcher. `proxy/main.go` binds
`:0` and prints the port, and Python reads that line into `SessionState`;
nothing hands the proxy a port. That keeps the port owned by a listening socket
from the moment it exists, so the `localhost:<port>` grant in the computed
profile cannot be claimed by anything else between computing it and launching.

Correctness fixes that come free. `lib/linux/symlink-helpers.nix` builds
`STATE_DIR_BINDS="$STATE_DIR_BINDS --bind ${dir} ${dir}"` and
`lib/linux/default.nix` expands it unquoted, so a declared path containing
whitespace splits into several bubblewrap arguments, and a path whose second
field begins with `--` becomes a flag. A Python list cannot do either, whether
bubblewrap reads it from a descriptor or from its own argv: what fixes it is the
values being separate list entries rather than one string something re-splits.
Keep it NUL-separated end to end; converting from newlines with `tr` would
reintroduce the vector for paths containing newlines.

The route-restrict layer moves to Python. The two `writeScript` scripts in
`lib/linux/networking.nix` become one entry point that runs inside pasta's
namespace, applies `network.json` and execs onwards. The rules are computed by
`compute_launch_config` and written as an artifact, so the entry point holds no
policy and the nftables rules stop being a third generated artifact. It keeps
the bash's fail-closed behaviour: a failed route deletion, ruleset load or
sysctl write exits with a reason rather than falling through to the exec.
`allowedLocalPorts` also needs two `/proc/sys/net/ipv4/conf/*/route_localnet`
writes, which an nft ruleset cannot express, so those stay in the entry point.
The `SANDBOX_PROXY_PORT="$_PROXY_PORT"` assignment prefixed to the pasta
invocation disappears: a shell assignment prefix cannot be an argv element, and
once the port is baked into the computed rules nothing reads the variable.

The fd 3 note, which is the one thing in this plan that was wrong rather than
merely incomplete. `bwrap --args` does exist on the pin, `--args FD  Parse
NUL-separated args from FD`, so that half was fine. But pasta does not pass an
inherited descriptor to its child: inside pasta, `cat <&3` gives EBADF, and
bubblewrap dies with `Can't read --args data: Bad file descriptor`. Every launch
failed, and it failed in the way that hides the cause, because the negative
assertions in the suite pass for free when nothing runs.

The claim that inline arguments give up whitespace safety was also wrong.
`argv-after-env` is already NUL-separated and expanded as `"${ARGV_AFTER_ENV[@]}"`,
so every entry survives spaces and newlines. The safety was never in the args
file; it was in the values being argv entries rather than a re-split string. So
the arguments go inline, and `bwrap.args` is still written because the bind list
on its own is the thing worth reading when a path is missing inside the sandbox.

The alternative was opening the descriptor after pasta, in the network entry
point, which is the only process we control between the two. It works, and it
was rejected: it puts bubblewrap's argument passing inside the module that
configures the namespace, and the property it buys, keeping bind paths off
`/proc/<pid>/cmdline`, is not available anyway. The spec lists every declared
path and sits world-readable in the store, and the session directory path is on
the cmdline regardless, since `argv-before-env` passes it to that entry point.

Still unverified: whether the macOS passwd file has any reader at all. It is
written to the session directory and granted by name in the profile, but there is
no bind on macOS and nothing points a library at that path, while macOS resolves
users through opendirectoryd over Mach IPC. If it has no reader, Darwin loses a
file, a profile rule and a cleanup entry.

The Linux symlink gap, fixed in 4a54d6d and 286da10, and worth recording
because the fix this plan proposed would not have worked. `HostState` recorded
chain hops in physical form, so a symlinked directory in the middle of a hop was
resolved away: given `x/a -> y/b`, `y -> z` and a real `z/b`, the chain said
`x/a -> z/b` where the bash said `x/a -> y/b`, because its walk used `cd` plus
`pwd` and bash reports the logical path.

It matters on Linux only. Seatbelt sees paths after the kernel has resolved
them, so `z/b` is what a macOS rule needs and `y` never appears in a check.
Bubblewrap builds a mount tree, so a name exists inside only if something was
mounted at it: binding `y/b` made bwrap materialise `y`, and binding `z/b` does
not, while the link text still says `y/b`. Demonstrated rather than reasoned
about this time: with only the physical target bound, opening the declared path
inside a real sandbox gives ENOENT.

The proposal here was to record the intermediate as an ordinary hop. That does
not work. The intermediate is not under `/nix/store`, and chain targets outside
the store are refused so an agent cannot plant a symlink that expands the
sandbox on the next launch, so the extra hop would have been warned about and
ignored, exactly as the bash did. What works is `--symlink`, reproducing the
host's symlink inside the sandbox instead of binding a path through it: a name
grants no access on its own, so the store restriction still decides what is
readable, and the sandbox ends up agreeing with the host about what that name
is. `SymlinkHop.parent_symlinks` carries them, and `DeclaredPath` carries its
own, since a declared path's parents were being flattened the same way.

The bash was not working either, which is the part worth remembering: it warned
and bound nothing, so the file was unreadable. The port turned a loud failure
into a silent one, and no test covered the shape. `tests/linux/test-symlinks.sh`
says so in a comment: every case it has is a direct store symlink, where the
logical and physical forms are identical.

Highest risk. Bubblewrap is order-sensitive about mount destinations, and
`mkResolveFileBashStr` documents a case where no ordering of the binds works at
all, because bwrap resolves mount destinations against its own intermediate root
where an absolute symlink target does not exist. Some of the apparent repetition
in the resolve generators may turn out to be load-bearing.

Order is load-bearing on both platforms, since bubblewrap mount destinations
overlay and seatbelt is last-match-wins, so a reordering that preserves the rule
set can still change what is enforced. There is no mechanical before-and-after
diff to catch that. The end-to-end suite is what stands behind this unit, and it
asserts outcomes at the paths it happens to check rather than the whole emitted
configuration. That risk is accepted deliberately.

Acceptance: the suite passes, mypy strict is clean, and the behaviour changes
above are in the release notes.

Four things the cutover found, all of them in code this plan called low risk.
The git-root-is-home rule had only ever been written in `darwin.py`, so Linux
bound a repository rooted at `$HOME` anyway, which the bash refused: it is
shared policy and now lives in `launch_config/shared.py`. The relative-path
refusal was listed under Behaviour changes as if it had shipped, and nothing
implemented it. `apply_network_rules` aborted with a traceback where the bash
printed a reason, on the path that removes the default route. And the two
backends each carry their own copy of the launcher package, the env fragment and
the stub substitution, so pinning the stub's interpreter in one left the other
building a wrapper with `@bash@` in the shebang, which no Nix check can catch.
That duplication should be factored into `shared.nix` now that the suite can say
whether it broke.

Left over, small: a regression test for a chain running through a symlinked
directory, which is the one defect from the port the suite would not have
caught; `shellcheck lib/stub.sh`, which unit 4 picks up anyway; and a
`_physical_path` helper, since realpath-the-parents-keep-the-name is now written
out inline in two places with a long comment each.

### 3. Session directory

Done. 9 files. The log is `launch.log`, not `startup.log`: it records the whole
launch rather than its start, and the name matches the vocabulary around it,
`prepare_launch`, `launch_checks`, `SandboxLaunchConfig`.

What the Session directory section above describes but unit 2 did not need in
order to write its artifacts: the log, and the warning when a declared path
covers the root. What the log may hold, and why the env keys come from Nix, is
under Secrets above.

Retention shipped with the port instead, for the reason recorded under Session
directory. It is 25 directories, pruned at launch, as a constant in the Python
source rather than a `mkSandbox` argument.

Logging is best effort and never gates a launch: a failed append leaves the
sandbox running normally. This inverts the convention in the surrounding code,
where a missing bind exits 1, and says so in `launch_log`.

An unwritable root was listed here as the same kind of failure, and it is not.
That sentence predates the port, when the directory held only debug artifacts.
It now holds the argv the stub reads and the profile the kernel reads, so a
launch cannot be assembled without it: `create_session_dir` refuses with a
reason where it used to raise `PermissionError` through to a traceback. Best
effort applies to the log, not to the directory.

No toggle and no Nix argument. Everything logged is cheap, bounded and already
computed. A toggle you must set before the failure means reproducing the failure
first, which is the hard part of sandbox bugs. No stdout option either: `prepare`
prints the session directory on stdout and the stub reads it from there, so
anything else written to it lands inside `$SESSION_DIR`.

Written in two goes rather than buffered and written at the end, because
`prepare` has more than one exit. The request section lands before the host is
read, so it survives whatever happens next; the second section lands at whichever
exit is reached, and is the outcome, the refusals, or a traceback. The first two
come from the same tuples that are printed to the terminal, so everything
printed is also in the log and the log holds more. The one exit not covered is
the proxy failing to report a port, which is already in `proxy.log`, named by
every one of those messages.

The traceback case was missed when this was designed, and is the one failure
whose evidence existed nowhere but the terminal: a bug in the launcher, a host
that could not be read, an interrupt during the confirmation prompt or the proxy
wait. `prepare_launch` catches `Exception` and `KeyboardInterrupt` around the
platform fold, writes the traceback and re-raises. Deliberately not
`BaseException`: `SystemExit` carries the refusals, which have already written
their own section, and catching it would record them twice. There is no
regression test for this yet, because triggering it from a shell test means
hand-mangling the spec out of a built wrapper; it belongs in unit 4's pytest
tier, where `prepare_launch` can be called with a broken spec directly.

The exit status is recorded by `cleanup`, from `$?` captured in the stub's EXIT
trap. That is as far as capturing the run can go: the sandboxed process's own
output is the user's terminal and holds their source and their prompts, so
capturing it would need a pty and would cost the property that the directory is
safe to attach to an issue.

Warn at launch if a declared `rwDir` or `rwFile` covers the sessions root, since
that hands the agent write access to the configuration and logs of every
session, including the running one. A warning rather than a refusal: the root is
relocatable and an `rwDir` on `$HOME/.local/state` is a plausible accident.

Split out of unit 2 because unit 2's risk is concentrated entirely in bind
ordering and seatbelt rule ordering, and this shares none of it. By the time it
landed, the directory and the artifacts already existed, so nothing moved.

Left over, and agreed rather than deferred: one `sandbox-readable/` subdirectory
holding the three files the sandboxed process reads, `ca-bundle.pem`,
`ca-cert.pem` and `passwd`. The split that earns a directory level is not
runtime versus debug, which is twelve files against three, but what the sandbox
can read: those three are granted by name on macOS specifically so a subpath
grant would not also hand over `proxy.pid`, and bound individually on Linux, so a
directory would make a by-convention rule structural and collapse three grants
into one. It waits on the question unit 2 left open, whether the macOS passwd
file has any reader at all, since the answer may drop a file from the set.

Acceptance: the suite passes, plus `tests/shared/test-launch-log.sh` covering
what is logged, what is not (declared env values), the refusal path, the
covers-the-root warning and the unwritable root. Pruning is covered by
`tests/shared/test-session-retention.sh`, which came with it.

### 4. Test tiers

Not started. 6 files. 2 days.

A pytest tier against `compute_launch_config`, which needs no `nix-build` and
no sandbox launch. Cover the symlink chain walk, the bound-prefix check,
parent-dir emission and the git protected-path enumeration.

Most of it runs on macOS against the Linux logic, since it is path manipulation.
That is the point: a macOS maintainer currently has no way to execute the Linux
code they are reviewing.

The tier boundary must not blur. A unit test proves the pure layer computed the
right configuration. Only end-to-end tests prove the kernel enforced it.
`test-git-hook-injection`, `test-rodirs-symlink-hardening`,
`test-user-folders-denied` and `test-nix-store-isolation` stay end-to-end
permanently. Converting an enforcement test into a unit test would look like a
speedup and be a security regression in the suite.

Add mypy strict and shellcheck to `.github/workflows/test.yml`. Shellcheck has
almost nothing left to check, which is the intended end state.

Add `ruff check --select F401,F811,F841` alongside them: unused imports,
redefinitions, unused locals. Deliberately not the whole of ruff, and no
`[tool.ruff]` section, so this is not an adoption of its formatting or style
opinions. mypy strict does not look for dead imports, and two had already
accumulated in the launcher by the time the modules were finished.

Acceptance: the suite passes, mypy and shellcheck run clean in CI, and the unit
tier covers the four areas above on both platforms.

### 5. Security backlog

Not started. Around 6 files. 2 days.

Findings from https://github.com/ofekd/agent-sandbox.nix/commits/hardening/,
deferred here because each lands in code unit 2 rewrites. Each has an issue
filed; close them from here.

Launcher-derived paths are not resolved to physical form before becoming
seatbelt rules, and the kernel resolves symlinks before the seatbelt hook, so
rules against a path under `/tmp` or a symlinked home silently match nothing.

The macOS profile grants blanket `file-write*` on `/tmp` and `/private/tmp`. The
CA bundle, CA cert and passwd file move into the session directory under unit 2,
which removes most of the exposure, but `$SANDBOX_HOME` still lives under
`/private/tmp` and a sandbox can still overwrite a concurrent session's copy.
Deny the name patterns after the rwDirs and roDirs allows so no user config can
re-grant them, then re-allow this session's own HOME.

The grant survives unit 2 for two reasons only: the sandbox HOME lives under
`/private/tmp`, and `TMPDIR` is set to `/tmp` so programs find scratch space
where they expect it. Pointing `TMPDIR` at a directory inside the sandbox HOME
would remove the second, at which point `/tmp` needs no grant beyond the home
itself and the deny-then-re-allow dance is unnecessary. That is a behaviour
change for anything hardcoding `/tmp` rather than respecting `TMPDIR`, which is
why it is not folded into the port, but it is the smaller end state and worth
weighing against the patterns approach.

`roDirs` and `roFiles` nested inside a read-write path stay writable on macOS.
Not for the reason previously recorded here: the read-only rules are emitted
last, not first. Seatbelt matches per operation, and `(allow file-read* (subpath
X))` says nothing about `file-write*`, so for a write under a nested `roDir` the
only matching rule is still the enclosing `rwDir`'s `file-write*` allow. No
ordering fixes that, at any position. The fix is an explicit `(deny file-write*
(subpath X))` emitted after the read-write allows, which is why
`seatbelt_profile_lines` is an ordered sequence rather than a template.

The symlink walk continuing from an invented cursor when a hop cannot be
resolved is fixed by unit 2 deleting the function. Confirm with a test rather
than assuming.

Plus the full nested-bind resolution deferred from S2.

Acceptance: the suite passes, plus one regression test per finding.

### 6. Duplication left by the port

Not started. Around 7 files. 1.5 days.

Two kinds of repetition, both introduced by unit 2, both cheaper to remove now
that the layers either side of them have settled.

The first is in the Nix. `lib/linux/default.nix` and `lib/darwin/default.nix`
share 139 lines, which is all but nine of the darwin file: the argument list,
`preEntryScript`, `implicitPackages`, `pathStr`, `closurePathsFile`,
`validatedAllowedLocalPorts`, the `launcherSource` filter, `launcherPackage`,
`envFragment`, the `stub` substitution and the whole `builtins.seq` tail are
identical text in both. What actually differs is the platform string, whether
`coreutils` enters the closure, `hostsFile` and `emptyFile`, and the doc comment.
The shared part belongs in one place, leaving each platform file holding the
differences and the debugging notes that are genuinely about its own backend.
Silent divergence is what this removes: a fix to the closure or to the stub
wiring has to be made twice today, and nothing fails if it is made once.

The second is the platform unions. `SandboxBuildSpec{Linux,Darwin}`,
`HostState{Linux,Darwin}`, `SessionState{Linux,Darwin}` and
`SandboxLaunchConfig{Linux,Darwin}` are four independent unions all encoding one
bit, which is known at build time and already in the spec. The type checker
cannot see that the four agree, so `prepare._compute_launch_config` re-establishes
the platform with a nine-way `isinstance` conjunction and carries an unreachable
arm reporting that the types do not agree, and `_CommonBuildSpec` duplicates the
entire field list of `SandboxBuildSpec` so that `**common` is checked at all.
Narrowing once, on the platform read out of the spec, and running a per-platform
path from there removes the conjunction, the unreachable arm and the reason
`_CommonBuildSpec` exists. This plumbing is a meaningful share of the line count
the port added, so the unit is a subtraction rather than a rearrangement.

What the shared Nix and the per-platform path are called is not settled, and is
decided when the unit is written rather than here.

Acceptance: the suite passes, mypy strict is clean, the two platform Nix files
hold only what differs between the platforms, and no platform re-narrowing
remains in `prepare`.

## Totals

Units 0, 1, 2 and 3 are done, plus both security fixes and AF_UNIX sockets. What
remains is unit 4, the pytest tier and the CI checks; unit 5, the security
backlog; and unit 6, the duplication left by the port. Neither of units 4 and 5
depends on the other, and unit 4 is the one that pays for itself fastest now
that the pure layer exists to test. Unit 6 goes after unit 4, since the pytest
tier is what makes collapsing the unions a checkable change rather than a
hopeful one. Unit 3 left one thing behind, the `sandbox-readable/`
subdirectory, which is recorded there.

## Decisions still open

Whether the pytest tier needs a nix devshell of its own, or rides on the
existing one.

Nothing further on names. Modules follow one rule, one module per type family
named for the type it owns, with `launch_checks`, `seatbelt` and `constants` as
the exceptions that own no type. Types carry the `Sandbox` prefix and modules do
not, since a module path is already `launcher.something`.

Settled since: what the root override variable is called, by deciding it stays
undocumented, which is recorded under Session directory. The fixtures' nixpkgs
comes from `tests/pinned-nixpkgs.nix`,
which reads the revision and hash out of `flake.lock`, and fixtures default to
it rather than taking it from the harness, so building one by hand is pinned
too.

## Deferred

A version string in `launch.log` for issue triage. There is no version in the
Nix source today, only tags and `CHANGELOG.md`, so it needs its own change.

Proxy allow-side URL logging, with its own opt-in. It is high volume and would
stop the session directory being safe to attach to an issue.

Letting `rwDirs` and friends vary without a rebuild, now that the seatbelt
profile is generated at runtime and nothing structural prevents it. This is a
capability change, not a refactor, and the reasons not to want it are separate.
