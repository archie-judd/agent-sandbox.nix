# Issues to file — agent-sandbox.nix

Findings from reviewing `ofekd/agent-sandbox.nix@hardening` (42 commits, branched
at release 2.3.0, before the python migration) against current `main` at `ef6828f`.
Features excluded, as agreed.

Line references are against `ef6828f`. The git readers move from `host_state.py`
into `git_state.py` in the pending change, so those are cited by symbol name.

**Housekeeping first:** issue **#101**, titled `x`, is junk I created while probing
token permissions. Please close or delete it. Sorry about that.

**Already handled, no action:**

- **#82** (seatbelt rules do not match non-physical paths) is already closed.
- The `repo_root` over-grant in worktrees and submodules is fixed in the pending
  working-tree change, so it is not filed below.

______________________________________________________________________

# Part 1 — updates to existing issues

## #84 · macOS: roDirs and roFiles nested inside a read-write path are writable

**Action:** comment, keep open.

Re-checked against `ef6828f`, after the python migration. Still present, but narrower than when this was filed.

`_get_nested_bind_conflicts` (`launcher/lib/launch_checks.py:51-100`) now refuses the nesting outright, so the case is closed where it applies. It is gated twice: darwin only (`:158`), and only for declared paths under `$HOME` (`:64`).

Uncovered, and still writable:

- A roDir or roFile inside the launch directory. `cwd` never enters `host.declared`, and `seatbelt.workspace` grants `file-write*` on its subpath (`launcher/lib/launch_config/darwin/compute.py:213`).
- A roDir or roFile under `/tmp` or `/private/tmp`, covered by the blanket write grant in `seatbelt.temp_dirs` (`seatbelt.py:182-192`, emitted at `compute.py:209`, before the declared-path allows at `:215`).
- A roDir or roFile inside an rwDir that is not under `$HOME`.

`seatbelt.declared_paths` already documents the mechanism at `seatbelt.py:256-258`: seatbelt matches per operation, so a read allow never outranks a write allow, and reordering cannot fix it.

The fix pattern is already in the tree. `seatbelt.unix_sockets` emits `nested_ro_dirs` / `nested_ro_files` denies for `network-bind` (`seatbelt.py:344-349`), computed by `_get_unix_socket_scope` (`compute.py:82-113`). The same nesting test, emitting `file-write*` denies after `declared_paths` and before `git_protection`, closes this.

Linux is unaffected: `linux/compute.py:179-184` binds cwd, then rw dirs, then ro dirs, and the later bind wins.

Test coverage gap: `tests/fixtures/ro-binds-sandbox.nix` declares only non-nested paths, so nothing exercises this today.

______________________________________________________________________

## #81 · Linux: symlink walk continues from an invented path when a hop cannot be resolved

**Action:** comment, keep open. Retitle suggested.

Mostly fixed by the python migration. The bash walker this was filed against is gone, replaced by `resolve_path` in `launcher/lib/symlinks.py`, which walks per component and records what it followed.

Two branches of the original class survive:

1. `symlinks.py:128-132`. `os.path.islink` returns true, `os.readlink` then fails, and the walk does `resolved = current; continue`. It keeps walking the remaining components underneath a path that is a symlink rather than a directory, so `physical_path` can name something the kernel never presents.
1. `symlinks.py:118-125`. On exhausting `MAX_SYMLINK_FOLLOWS` it builds `current.joinpath(*remaining)` and returns that as `physical_path`, with no warning. The kernel would answer ELOOP for that path.

Both are milder than the original bash bug. The fabricated path fails the `exists` check, so `get_launch_refusals` refuses the launch rather than binding something undeclared. The failure mode is a confusing message, not a hole.

Suggested fix: stop the walk and warn, naming the link and its target, rather than continuing from it or fabricating a tail.

Suggested retitle: *Linux: resolve_path continues past, or fabricates, an unresolvable hop*.

______________________________________________________________________

# Part 2 — new issues

Ordered by my read of severity. The first is the only one I would call urgent.

## 1. Proxy: the Host header is not checked against the CONNECT authority

`applyFilters` judges the host the connection was opened for. `req.Write` forwards the client's own `Host:` verbatim.

- `proxy/main.go:451` passes `host`, derived from the CONNECT authority, into `handleMITM`.
- `proxy/main.go:574` runs `applyFilters(req, host, cfg)` against that same authority-derived host for every request inside the tunnel.
- `proxy/main.go:608` writes the request upstream with the client's `Host:` header untouched.

So `CONNECT allowed.example:443`, followed inside the tunnel by `Host: other.example`, passes the allowlist on one name and is served by the other. On a shared TLS edge the Host header is what selects the origin. Keep-alive pins the upstream connection, so one mismatch is inherited by every request sent after it.

`hostOnly` (`proxy/main.go:175-181`) has a second seam. It returns the raw address when `net.SplitHostPort` fails, and it never inspects brackets, so a bracketed authority is stripped without anything checking what is inside it. `CONNECT [allowed.example]:443` with `Host: [allowed.example]` passes the allowlist on `allowed.example` and matches itself, because both sides reconstruct identically.

"It would fail the allowlist anyway" is not true: `lookupPolicy` falls back to a `"*"` entry for any unmatched host.

Fix: require the two to name the same host before forwarding, and make `hostOnly` return `(host, ok)` and refuse a bracketed authority whose content is not an IPv6 literal. Both checks belong at the gate in `handle`, before the `200 Connection Established`.

Upstream reference: `ea07114c`.

______________________________________________________________________

## 2. Proxy: a non-ASCII host can be delivered to a different origin

`lookupPolicy` folds with `strings.ToLower` (`proxy/main.go:120`), which is a Unicode fold. `loadConfig` folds allowlist keys the same way (`:91`).

An authority spelled with U+212A KELVIN SIGN folds to `k`, so it matches a `k.example` allowlist entry. The request is then dialled through `idna.Lookup`, the mapping profile, while `Request.write` punycodes the `Host:` line through the non-mapping profile. Three names, one request. U+0130 is the same trick against an `i.example` entry.

The key side matters on its own: an allowlist key written with U+0130 is stored under its ASCII name, so the entry admits requests to a host the operator never wrote. That is the collision running backwards, widening the allowlist.

Under a `"*"` catch-all the misdelivery needs no collision at all: the authority passes the allowlist on its own bytes, matches itself in any Host check, is connected to at one name and delivered as another.

Fix: refuse a host carrying a non-ASCII byte, as one test on `req.Host` in `handle`, ahead of the CONNECT branch (the `200` and the client handshake precede any per-request check). Convert every fold in the file to an ASCII-only fold, on both the lookup side and the key side. Internationalized domains then have to be written in punycode, which is worth a startup warning beside the allowlist load.

Cheap to do alongside issue 1: same function, same class of bug.

Upstream reference: `6338cc63`.

______________________________________________________________________

## 4. Proxy: SANDBOX_PROXY_REDIRECT is inherited from the launching shell

`_start_proxy` (`launcher/lib/session_state.py:136-151`) builds `environ = dict(os.environ)` and then sets `SANDBOX_PROXY_REDIRECT` only when `proxy.redirects` is non-empty. With no redirects configured, whatever the user's shell exported passes straight through to the proxy.

A redirect is the most powerful input the proxy takes. `lookupRedirect` is consulted after `isDomainAllowed` and `applyFilters` have run, and both key off the original host. The dial that follows skips `resolveVetted` (`proxy/main.go:536-540`), so the target may be loopback or anything on the LAN, and on the MITM path it is a bare `net.Dial` with no upstream TLS, so a redirected HTTPS request leaves in cleartext.

Fix: set the variable unconditionally. `parseRedirectEnv` already reads `""` as no redirects (`proxy/main.go:40-42`), so collapsing the empty branch into the general one is sufficient. One line.

Upstream reference: `bc61a838`.

______________________________________________________________________

## 5. Proxy: no timeouts, header caps or connection cap on client connections

`handle` calls `http.ReadRequest` directly (`proxy/main.go:432`, `:569`). `MaxHeaderBytes`, `ReadHeaderTimeout`, `ReadTimeout` and `IdleTimeout` are fields on `http.Server`, not on the parser, so none of them applies here.

A connection can sit open with no request on it until the session ends, send its headers one byte at a time, or send headers without end. Nothing bounds the number of concurrent connections.

The upstream TLS handshake is also unbounded. `handle` fills in a scheme only when the request did not carry one, so an absolute-form `GET https://host/` on the plaintext path reaches `directTransport` with `https` intact and runs its handshake at `TLSHandshakeTimeout: 0`. `directTransport` has no `IdleConnTimeout` either, so its pooled upstream connections are never reaped.

Fix: add the `http.Server` analogues explicitly. An idle wait for the first byte of a request (on a MITM tunnel this is also the wait between requests, so it must clear a client's own idle-reuse window), a separate header-block deadline, a header byte cap and a header field count cap, a per-operation read and write deadline, and a concurrent connection cap that answers 503.

If a wrapper type carries the deadlines, embed the `net.Conn` interface rather than a concrete type. That is what stops it satisfying `io.ReaderFrom` / `io.WriterTo`, and therefore what stops `io.Copy`'s splice fast path routing around the deadlines.

Upstream reference: `74474e2d`.

______________________________________________________________________

## 6. Proxy: the accept loop spins a core on a persistent error

`proxy/main.go:420-426`:

```go
for {
	conn, err := ln.Accept()
	if err != nil {
		continue
	}
	go handle(conn, cfg, ca, redirects)
}
```

Nothing in this file sets a deadline, so concurrent CONNECTs can drive the process to EMFILE. After that `Accept` fails immediately and forever, and the loop burns a core for the rest of the session. It is also the quietest outcome in the log, because nothing is written at all.

Fix: ramp a retry delay on a temporary error. Reach the predicate through `errors.As` rather than a type assertion, since a single-level `err.(net.Error)` misses both a wrapped error and a bare `syscall.Errno`. Track consecutive unclassified failures separately, reset by a recognised error and by a success, so an unfamiliar errno arriving during an EMFILE storm cannot trip a budget the storm filled.

Depends on issue 5 for the underlying cause: descriptors are held by handler goroutines that block with no deadline anywhere, so what frees one today is the client closing.

Upstream reference: `b9403e4b`.

______________________________________________________________________

## 7. git: objects/info/alternates is not pinned read-only

`_get_protected_files_in_gitdir` pins `config`, `config.worktree`, the worktree pointer files and a submodule's `.git` file. It does not pin `objects/info/alternates`.

`alternates` redirects object lookup rather than execution, and objects are content-addressed, so nothing can be substituted. What it does allow is for a repository to pass `fsck` against object stores the sandbox chose the location of, and to be corrupted when those stores vanish.

Fix: add it to the same list, at every submodule depth, on both platforms.

One caveat before reusing the existing missing-file treatment: an empty placeholder is not inert for every pointer file the way it is for `hooks`. Check what git does with a zero-byte `alternates` before reusing the `empty_file` bind at `launcher/lib/launch_config/linux/binds.py:261`.

Upstream reference: `2fc49d08`.

______________________________________________________________________

## 9. Proxy: a redirect entry can be forged through a key containing a comma

`_start_proxy` (`launcher/lib/session_state.py:139`) builds the value as `pairs = [f"{host}={address}" ...]` joined with `,`. `parseRedirectEnv` splits on `,` and then on the first `=` (`proxy/main.go:43-48`). Neither side checks the shape of a host or an address.

A host key containing a comma therefore forges an entry the caller never wrote, and a forged redirect is worth what a written one is, because the dial skips `resolveVetted`.

The shell-injection half of the upstream finding does not apply: values no longer reach a shell after the python migration. This is the grammar half only.

`_proxyRedirects` is an internal test hatch rather than a documented option, which is why this is low severity. Fix: shape-check each host and address at eval time in `lib/spec.nix`, so the string cannot be built from parts that would re-split.

Upstream reference: `72f4b4ff` (grammar half only).

______________________________________________________________________

## 10. Proxy: "\*" is documented as a default policy, which understates what it permits

`proxy/main.go:30` says `// The "*" key is the default policy.` That reads as a floor for hosts the caller forgot to list. It is not. `lookupPolicy` (`:137-139`) applies it to every host that no exact or suffix entry matched, so `{ "*" = [ "GET" ]; }` permits GET to the whole internet.

Matching behaviour is correct and should not change. What is missing is an accurate description and a warning.

Fix: document the precedence explicitly (exact key, then longest suffix with `"*"` excluded, then `"*"`, then deny, with exactly one entry applying and policies never merging), and warn at startup when a `"*"` key is present, naming what it actually permits.

Worth stating alongside it: a catch-all widens which hosts pass the filter, but every `allowedDomains` value still routes egress through the proxy, so it is HTTP and HTTPS on 80 and 443 only, with no DNS and no other protocol. Only `allowedDomains = null` takes the unproxied path.

Upstream reference: `d3be4e59`.

______________________________________________________________________

## 11. chore: unpinned CI action, unpinned shell tarballs, deprecated stdenv aliases

Three small hygiene items, grouped because each is a few minutes.

**Unpinned CI action.** `.github/workflows/test.yml:36` uses `actions/checkout@v4`. A tag is mutable, so retagging runs new code on every push. `DeterminateSystems/nix-installer-action@v16` (`:38`) and `googleapis/release-please-action@v4` (`.github/workflows/release-please.yml:15`) are in the same position, and release-please runs with `contents: write` and `pull-requests: write` on every push to main.

**Unpinned tarballs in the shipped examples.** All four `shells/*.nix` do `import (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")` with neither a rev nor a hash, so a single push to main silently rewrites every copied shell, proxy binary and sandbox profile included.

**Deprecated stdenv aliases.** `pkgs.stdenv.isDarwin` / `isLinux` are deprecated aliases for the `hostPlatform` predicates; nixpkgs warns on them and will eventually drop them. Three occurrences: `default.nix:14`, `shells/claude-uv.shell.nix:17`, `tests/fixtures/network-allowed.nix:12`. `hostPlatform` is the correct axis, since the wrapper runs on the machine it is built for.

Upstream references: `ec9b67e7`, `6f7fbb1e`, `1fd571d6` / `e88c02a4`.

______________________________________________________________________

# Deliberately not filed

- **Docker's seccomp profile** (`02003f35`). An 833-line JSON blob plus a C compiler plus a build step, against a threat bubblewrap largely already covers with `--unshare-all`, no capabilities and a single uid. Largest maintenance surface in the fork, smallest marginal win.
- **Credential scanning** (`b2e9b17a`, `0246a900`). By its own commit message it does not cover base64, re-encoding, a value split across requests, bodies, or a token the launcher never saw. A lot of permanent machinery for a guard a mildly adversarial agent steps around, and the fork reverted a third of it in `16b53581`.
- **Private-range blocking in `resolveVetted`**. `proxy/main.go:341-343` states the divergence deliberately, and allowlisting an internal server is a legitimate configuration.
- **All features** (`cwdMode`, `{ src, dst }` binds, `allowedDomains` defaulting to `[ ]`, env credential `hosts`), as agreed.
