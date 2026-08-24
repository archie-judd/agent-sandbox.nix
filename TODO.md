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
build/                nix only: mkSandbox, validation, writeClosure, spec.json
launch/
  proxy/              go, moved unchanged
  stub/stub.sh        the static bash stub
  launcher/
    pyproject.toml
    agent_sandbox/    python
tests/
```

`proxy/` sits under `launch/` because it is a runtime component, even though
like everything else it is built at build time. The Python gets a directory of
its own under `launch/` rather than sitting directly in it, so that the
`buildPythonPackage` source root does not also contain the Go proxy and the
stub, which would rebuild the launcher whenever either changed.

Inside the package, one module per type family, named for the type it owns:

```
agent_sandbox/
  __init__.py              empty, deliberately
  constants.py             artifact filenames, retention, deadlines, listen address
  build_spec.py            SandboxBuildSpec, Dependencies, ProxySpec
  host_state.py            HostState, DeclaredPath / File / Dir, GitState
  session_state.py         SessionState, ProxyState
  launch_checks.py         check_launch_allowed, and the only prompt in the program
  launch_config/
    shared.py              SandboxLaunchConfig, write_launch_config
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

mypy strict, fully annotated.

Packaged with `buildPythonPackage`, not `buildPythonApplication`. The latter
emits a bash wrapper per console script that sets `PYTHONPATH` and execs the
interpreter, and that wrapper runs on every launch, in front of every entry
point. `buildPythonPackage` generates no wrappers, and gives the mypy and pytest
runs a `checkPhase` to live in, which is where a Nix reader will look for them.

The stub sets `PYTHONPATH` inline and invokes `python3 -P -s -S -m
agent_sandbox.<entry>`. Not `-I`: isolated mode implies `-E`, which makes the
interpreter ignore `PYTHONPATH`, so the package would not be importable. `-P`
keeps cwd and the script directory off `sys.path`, `-s` drops the user site
directory, and `-S` skips `site` entirely, which is also where a chunk of the
startup cost lives. The residual exposure is a user with `PYTHONHOME` set, which
breaks loudly rather than silently.

`agent_sandbox/__init__.py` stays empty, with a comment saying why. The
in-namespace network entry point runs on the Linux hot path and needs only `os`
and `sys`, so it pays a bare interpreter start of around 16 ms rather than the
33 ms the full import set costs. Any re-export added to `__init__.py` would
silently hand it the whole package.

### Naming

Settled:

| Name | Meaning |
|---|---|
| `SandboxBuildSpec` | the JSON Nix emits at build time |
| `HostState` | what reading the host returns |
| `SessionState` | what the launcher creates for this launch |
| `SandboxLaunchConfig` | the pure result: argv segments, artifact bodies, warnings |
| `read_host_state` | observes, decides nothing |
| `check_launch_allowed` | refuses or continues |
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

Five, all needing release notes. Two have already shipped as security fixes.

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

Nested binds refuse at launch. Shipped in S2.

Loopback and link-local resolutions are refused by the proxy. Shipped in S1.

## Secrets

`env` values never touch disk. Both platforms pass them as `K=V` arguments to
`env -i`, so the args file and the profile stay free of them and the session
directory copy is verbatim and publishable. Linux drops bubblewrap's
`--clearenv` and `--setenv` to get there, which has the side benefit of moving
the values off `/proc/<pid>/cmdline`, readable by any user on the host, and into
`/proc/<pid>/environ`, readable only by its owner. Nothing needs redacting,
which is better than redacting correctly.

`startup.log`, once unit 3 adds it, records env keys without values, from the
keys-only list the spec already carries. Building that list in Nix from the same
attrset means it cannot be defeated by a value that looks like a flag.

The session directory must stay safe to attach to a GitHub issue. That is the
property the debug logging design is built around, and it is why proxy
allow-side URL logging stays out of scope.

Two files in the session directory are read by the sandboxed process: the CA
bundle via `SSL_CERT_FILE`, and the passwd file, if the passwd file turns out to
have a reader on macOS at all (see unit 2). Grant those two by name, not the
directory by subpath. Granting the subpath would also hand over
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
  bwrap.args        Linux, NUL-separated
  nft.rules         Linux
  seatbelt.sb       macOS
  passwd
  ca-bundle.pem     restricted mode only
  ca-cert.pem       restricted mode only
  proxy.pid         restricted mode only
  proxy.log         restricted mode only
  cleanup           NUL-separated paths to remove on exit
```

Everything except the sandbox home sits here at a fixed name. That is what lets
the stub read what it needs without being told, and what keeps `SessionState`
down to a directory, a proxy port and a pid. The sandbox home stays under
`/private/tmp` on macOS: moving it here would put it under the real home, which
changes what `(allow file-read* process-exec (subpath (param "HOME")))` grants.

NUL separation is not only for `bwrap --args`. The `cleanup` file and both argv
files use it too, because a path may contain a newline.

Root resolution: `AGENT_SANDBOX_LOG_DIR`, else `$XDG_STATE_HOME`, else
`$HOME/.local/state`. Timestamp leads the name so `ls` sorts chronologically and
pruning by name matches pruning by mtime. `outName` is in the name because
several wrappers share one root.

Created first thing, ahead of the bind-existence check, so a run refused for a
missing bind or a declined home-directory launch still records why.

The wrapper prints nothing about the directory on success or failure.
Discoverability is the README's job.

Unit 2 creates the directory and writes the artifacts. Retention, the startup
log and the warning when a declared path covers the root are unit 3, which adds
behaviour to a directory that already exists rather than relocating anything.
Until then directories accumulate unpruned, which is still an improvement on
`mktemp` files scattered across `/tmp`.

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

Not started. Around 25 files, almost all mechanical. 1 day.

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

Not started. Most of `lib/`, plus new `build/` and `launch/`. 5 to 8 days.

Both backends in one pass. `lib/shared.nix` feeds both, so splitting Linux and
macOS into separate PRs means porting the git protected-path enumeration twice
or shipping a half-Nix half-Python seam.

Move `proxy/` to `launch/proxy/` as its own commit first, so the Go diff is
empty.

The steps.

```
prepare_launch(spec_path) -> session dir
  spec        = load_build_spec(spec_path)
  session_dir = create_session_dir(spec)
  host        = read_host_state(spec)
                check_launch_allowed(spec, host)
  session     = create_session_state(spec, host, session_dir)
  config      = compute_launch_config(spec, host, session)
                write_launch_config(config, session)
```

`create_session_dir` is separate from `create_session_state` so the directory
exists before anything can refuse the launch, without a proxy having been
started for a run that is about to be refused.

`read_host_state` may read files, run git and resolve symlinks. It may not
create, delete, prompt or decide. `check_launch_allowed` holds the
bind-existence check, the home-directory confirmation, the git-root-is-home
refusal and the nested-bind refusal; all four are pure predicates over
`HostState` except the confirmation, which needs `/dev/tty`.
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
class DeclaredPath:
    unexpanded_path: str              # "$HOME/.claude", for diagnostics
    expanded_path: Path
    mode: Literal["rw", "ro"]
    exists: bool
    symlink_chain: tuple[Path, ...]   # empty when the path is not a symlink

class DeclaredFile(DeclaredPath): ...
class DeclaredDir(DeclaredPath):
    inner_symlinks: tuple[tuple[Path, ...], ...]

class GitState:
    common_dir: Path
    repo_root: Path
    worktree_config_enabled: bool
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
    nft_rules: tuple[str, ...]

class SandboxLaunchConfigDarwin(SandboxLaunchConfig):
    seatbelt_profile_lines: tuple[str, ...]
```

The artifacts stay sequences through `compute_launch_config` and only meet a
separator in `write_launch_config`. Flattening them earlier would throw away
the structure the `--args` change exists to protect, and would reduce the unit
tier to string matching. What the tests need to be able to write is that
`("--bind", "/tmp/a b", "/tmp/a b")` appears in `bwrap_args`, and that a deny
line's index exceeds an allow line's index in `seatbelt_profile_lines`, since
seatbelt is last-match-wins.

The launch line. Both platforms have the same shape, and the two computed
segments exist for exactly one reason, which is that the declared env values
have to be injected between them without passing through Python.

```
argv_before_env   Linux  pasta ... -- <nft entry> nft.rules
                         env -i <computed K=V>
                  macOS  env -i <computed K=V>

<declared K=V>           from the Nix env fragment, sourced by the stub

argv_after_env    Linux  bwrap --args 3  pre-entry  sandboxed-binary
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

The stub, in full, byte-identical for every build:

```bash
SESSION_DIR=$("@python@" -P -s -S -m agent_sandbox.prepare "@spec@") || exit 1
trap '"@python@" -P -s -S -m agent_sandbox.cleanup "$SESSION_DIR"' EXIT
source "$SESSION_DIR/../env-fragment"          # sets DECLARED_ENV=( K=V ... )
mapfile -d "" ARGV_BEFORE_ENV < "$SESSION_DIR/argv-before-env"
mapfile -d "" ARGV_AFTER_ENV  < "$SESSION_DIR/argv-after-env"
[ -e "$SESSION_DIR/bwrap.args" ] && exec 3< "$SESSION_DIR/bwrap.args"
"${ARGV_BEFORE_ENV[@]}" "${DECLARED_ENV[@]}" "${ARGV_AFTER_ENV[@]}" "$@"
```

The env fragment is a store path interpolated by Nix, not a session file; the
line above is shorthand. `--args 3` reads NUL-separated arguments from an
already-open descriptor, which is why the redirect happens in the stub and not
in Python: descriptors opened by a shell redirection are not close-on-exec, so
fd 3 survives pasta, the nft entry point and `env -i`, all of which clear the
environment rather than the descriptor table. The one conditional is on runtime
state, not on the build, so the file stays the same for every wrapper.

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
field begins with `--` becomes a flag. A Python list written NUL-separated to
`bwrap --args` cannot do either. Keep it NUL-separated end to end; converting
from newlines with `tr` would reintroduce the vector for paths containing
newlines.

The route-restrict layer moves to Python. The two `writeScript` scripts in
`lib/linux/networking.nix` become one entry point that runs inside pasta's
namespace, applies `nft.rules` and execs onwards. The rules are computed by
`compute_launch_config` and written as an artifact, so the entry point holds no
policy and the nftables rules stop being a third generated artifact.
`allowedLocalPorts` also needs two `/proc/sys/net/ipv4/conf/*/route_localnet`
writes, which an nft ruleset cannot express, so those stay in the entry point.
The `SANDBOX_PROXY_PORT="$_PROXY_PORT"` assignment prefixed to the pasta
invocation disappears: a shell assignment prefix cannot be an argv element, and
once the port is baked into `nft.rules` nothing reads the variable.

Three things to verify rather than assume. That `bwrap --args` exists in the
pinned nixpkgs: `bwrap --help | grep -- '--args'`. That fd 3 survives pasta into
bubblewrap, since the whole args-file design rests on it. And whether the macOS
passwd file has any reader at all: it is created at `lib/darwin/default.nix:635`,
passed as `-D SANDBOX_PASSWD` at `:680` and granted `file-read*` at
`seatbelt-profile.nix:142`, but there is no bind on macOS and nothing points a
library at that path, while macOS resolves users through opendirectoryd over
Mach IPC. If it has no reader, Darwin loses a file, a param, a profile rule and a
cleanup entry. The header comment at `lib/darwin/default.nix:76` already claims
the profile allows `/etc/passwd` and `/private/etc/passwd`, and it allows
neither.

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

### 3. Session directory

Not started. Around 4 files. 1.5 days.

What the Session directory section above describes but unit 2 does not need in
order to write its artifacts: retention, the startup log, and the warning when a
declared path covers the root. What `startup.log` may hold, and why it is built
in Nix, is under Secrets above.

Retention is 25 directories, pruned at launch, as a constant in the Python
source rather than a `mkSandbox` argument.

Logging is best effort and never gates a launch. An unwritable root, a failed
mkdir or a failed append must all leave the sandbox running normally. This
inverts the convention in the surrounding code, where a missing bind exits 1,
and needs a comment saying so.

No toggle and no Nix argument. Everything logged is cheap, bounded and already
computed. A toggle you must set before the failure means reproducing the failure
first, which is the hard part of sandbox bugs.

Warn at launch if a declared `rwDir` or `rwFile` covers the session directory
root, since that would hand the agent write access to its own logs.

Split out of unit 2 because unit 2's risk is concentrated entirely in bind
ordering and seatbelt rule ordering, and this shares none of it. By the time it
lands, the directory and the artifacts already exist, so nothing moves.

Acceptance: the suite passes, plus tests that an unwritable root still launches,
that pruning keeps the newest 25, and that a declared path covering the root
warns.

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

`roDirs` and `roFiles` nested inside a read-write path stay writable on macOS,
because seatbelt is last-match-wins and the read-only rules are emitted first.
Nearly free once Python owns the whole profile and its ordering, which is why
`seatbelt_profile_lines` is an ordered sequence rather than a template.

The symlink walk continuing from an invented cursor when a hop cannot be
resolved is fixed by unit 2 deleting the function. Confirm with a test rather
than assuming.

Plus the full nested-bind resolution deferred from S2.

Acceptance: the suite passes, plus one regression test per finding.

## Totals

Around 12 to 15 days across six units, one per PR. Unit 0 is done. Unit 1 is
around a day of test housekeeping and is the only thing standing before the
port.

## Decisions still open

How to pin the fixtures' nixpkgs in unit 1: a shared file deriving the revision
from `flake.lock`, a `--arg pkgs` threaded from `run-all.sh`, or a pinned
`fetchTarball` per fixture.

Whether the pytest tier needs a nix devshell of its own, or rides on the
existing one.

What the root override variable is called. `AGENT_SANDBOX_LOG_DIR` was named
when the directory held only logs, and it now holds the computed configuration
as well.

Nothing further on names. Modules follow one rule, one module per type family
named for the type it owns, with `launch_checks`, `seatbelt` and `constants` as
the exceptions that own no type. Types carry the `Sandbox` prefix and modules do
not, since a module path is already `agent_sandbox.something`.

## Deferred

A version string in `startup.log` for issue triage. There is no version in the
Nix source today, only tags and `CHANGELOG.md`, so it needs its own change.

Proxy allow-side URL logging, with its own opt-in. It is high volume and would
stop the session directory being safe to attach to an issue.

Letting `rwDirs` and friends vary without a rebuild, now that the seatbelt
profile is generated at runtime and nothing structural prevents it. This is a
capability change, not a refactor, and the reasons not to want it are separate.
