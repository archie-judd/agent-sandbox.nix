# agent-sandbox.nix

Lightweight and declarative sandboxing for AI agents on Linux and macOS.

Prevent your agents in YOLO mode from deleting your $HOME, force pushing to main, or publishing your ssh keys on reddit. Works with any CLI-based AI agent.

The sandbox uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux and sandbox-exec on macOS.

Tested with Claude's frontier models — see [Security](#security) for the threat model and known limits.

## What the sandbox allows

- **Project directory** — read/write access to the directory you launch the agent from.
- **Declared state** — read/write access to anything you list in `rwDirs` / `rwFiles`, or read-only access via `roDirs` / `roFiles`.
- **Allowed packages** — the binaries you list in `allowedPackages` are on the agent's PATH (plus `bash` and `cacert`).
- **Network** — unrestricted internet by default, with host-local services blocked. Set `allowedDomains` to limit internet domains, and use `allowedLocalPorts` for explicit host-local TCP port access.
- **Environment** — only variables you pass via `env` reach the agent; the host environment is otherwise cleared.
- **Git** — the repo's `.git` directory is exposed, including when it sits outside the project tree (worktrees).
- **Nix** — disabled by default. Optionally allow the agent to run nix commands.

Everything else is denied. `$HOME` is an ephemeral writable tmpfs that disappears when the sandbox exits.

## Contents

<!-- vim-markdown-toc GFM -->

* [Usage and configuration](#usage-and-configuration)
    * [Templates](#templates)
    * [Arguments](#arguments)
    * [Network restrictions](#network-restrictions)
* [Authentication](#authentication)
    * [Environment variable tokens (recommended)](#environment-variable-tokens-recommended)
    * [Credential files via `rwDirs`](#credential-files-via-rwdirs)
    * [Tested agents](#tested-agents)
* [Git](#git)
    * [Remote access (push / pull / fetch)](#remote-access-push--pull--fetch)
    * [Git identity](#git-identity)
* [Using Nix inside the sandbox](#using-nix-inside-the-sandbox)
* [Common Patterns / Recipes](#common-patterns--recipes)
    * [Python with uv](#python-with-uv)
    * [Node.js with npm](#nodejs-with-npm)
* [Troubleshooting](#troubleshooting)
    * [Filesystem access issues](#filesystem-access-issues)
    * [Network access issues](#network-access-issues)
    * [macOS: unexpected sandbox denials](#macos-unexpected-sandbox-denials)
    * [macOS: localhost service denials](#macos-localhost-service-denials)
* [Security](#security)
    * [What it protects against](#what-it-protects-against)
    * [What it doesn't protect against](#what-it-doesnt-protect-against)
    * [Specific things worth being aware of](#specific-things-worth-being-aware-of)
    * [Linux vs macOS](#linux-vs-macos)
    * [Is this the right tool for me?](#is-this-the-right-tool-for-me)
* [Caveats](#caveats)
* [Similar projects](#similar-projects)

<!-- vim-markdown-toc -->

## Usage and configuration

The quickest way to get started is with a flake template. If you prefer a `shell.nix`, see [`shells/`](shells/) for ready-to-use examples. Authentication is covered [below](#authentication).

<details id="v0x-to-v1x-migration-guide">
<summary><strong>V0.x to V1.x migration guide</strong></summary>
<br>

A few arguments were renamed, and `restrictNetwork` was removed. If you use an old name you'll get a clear error telling you the new one. Update your config like this:

| Old | New |
|---|---|
| `extraEnv = { … }` | `env = { … }` |
| `stateDirs = [ … ]` | `rwDirs = [ … ]` |
| `stateFiles = [ … ]` | `rwFiles = [ … ]` |
| `restrictNetwork = true; allowedDomains = …` | `allowedDomains = …` |
| `restrictNetwork = true; allowedDomains = [ ]` | `allowedDomains = [ ]` |
| `restrictNetwork = false` | remove it — just don't set `allowedDomains` |

Network access is now controlled by `allowedDomains` on its own: leave it unset for open internet, list the domains you want to allow, or use `[ ]` to block everything.

**If you relied on host loopback reachability:** previously, leaving `restrictNetwork` unset let the agent reach host-local services (Ollama, a local database, a local MCP server, etc.). That no longer works by default — host loopback is blocked unless you explicitly opt in with `allowedLocalPorts`.

</details>

### Templates

Flake templates for claude-code and github copilot CLI are provided for quick project setup, but you can alter either to work with any other CLI tool.

To initialize a template in your project directory:

```bash
nix flake init -t github:archie-judd/agent-sandbox.nix#claude
# or
nix flake init -t github:archie-judd/agent-sandbox.nix#copilot
```

This creates a `flake.nix` in your project (see [`templates/claude/flake.nix`](templates/claude/flake.nix) for what you get). Edit it to suit your needs, then enter the dev shell:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix develop --impure
```

> **Note**: Claude Code and most other AI CLI tools are not FOSS. You will need to set `NIXPKGS_ALLOW_UNFREE=1` and invoke the shell with `--impure`.

And invoke your wrapped binary:

```bash
claude-sandboxed --dangerously-skip-permissions # Claude Code's "YOLO mode"
# or
copilot-sandboxed --yolo
```

If you want to keep the original command name as the alias, change the `outName` value (e.g. to `"claude"` or `"copilot"`).

### Arguments

`mkSandbox`, the library's entrypoint, accepts the following arguments:

| Argument | Required | Description |
|---|---|---|
| `pkg` | yes | Package containing the binary to wrap |
| `binName` | yes | Name of the binary inside `pkg/bin/` |
| `outName` | yes | Name for the resulting wrapped binary and the command to invoke it with |
| `allowedPackages` | yes | Packages whose `bin/` dirs form the sandbox PATH. `bash` and `cacert` are provided by default — the sandbox needs a shell to run, and `cacert` is required for HTTPS to work. |
| `rwDirs` | no | Directories the agent can read/write (e.g. `~/.config/claude`) |
| `rwFiles` | no | Individual files the agent can read/write |
| `roDirs` | no | Directories the agent can read but not write (e.g. signed binaries, reference source trees, secret stores) |
| `roFiles` | no | Individual files the agent can read but not write (e.g. `~/.config/git/config` for git identity — see [Git identity](#git-identity)) |
| `allowNix` | no | If `true`, expose the host's `nix-daemon` socket and the full Nix store so the agent can run `nix build`, `nix run`, `nix develop`, etc. `pkgs.nix` is added to PATH automatically. Defaults to `false`. See [Using Nix inside the sandbox](#using-nix-inside-the-sandbox). |
| `env` | no | Additional environment variables as an attrset |
| `allowedDomains` | no | Limits which domains the sandbox can reach. Leave unset for open internet. Accepts a list of domains (all methods allowed), or an attrset mapping each domain to `"*"` or a list of HTTP methods. `[ ]` blocks all internet access. |
| `allowedLocalPorts` | no | Host-local TCP ports the sandbox may reach. Defaults to `[ ]`. Set to `null` to allow all host-local TCP ports. Otherwise, entries must be integers from `1` to `65535`. |

Paths declared in `rwDirs` / `rwFiles` / `roDirs` / `roFiles` must exist on the host before launch — the sandbox exits with a clear error if any are missing.

A minimal example — the arguments are the same whether you use a flake or a `shell.nix`:

```nix
mkSandbox {
  pkg = pkgs.claude-code;
  binName = "claude";
  outName = "claude-sandboxed";
  allowedPackages = [ pkgs.coreutils pkgs.git pkgs.ripgrep ];
  rwDirs = [ "$HOME/.claude" ];
  roFiles = [ "$HOME/.config/git/config" ];
  env = {
    CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
    CLAUDE_CONFIG_DIR = "$HOME/.claude";
  };
  allowedDomains = {
    "anthropic.com" = "*";
    "claude.com" = "*";
    "github.com" = ["GET" "HEAD"];
    "githubusercontent.com" = ["GET" "HEAD"];
  };
}
```

<details>
<summary><strong>Why set <code>CLAUDE_CONFIG_DIR</code> and not add <code>~/.claude.json</code> as a <code>rwFile</code>?</strong></summary>
<br>

`CLAUDE_CONFIG_DIR` is set to `$HOME/.claude` so that `~/.claude.json` is written inside the read/write `rwDir`. If you instead add `~/.claude.json` as a `rwFile`, when Claude updates configuration it writes temporary files to the ephemeral home root. It then tries to rename these to `~/.claude.json`, which can fail or behave unexpectedly because the temporary files land outside any declared `rwDir` or `rwFile`. This can occasionally corrupt the `~/.claude.json` file.
<br>
<br>

> **Note:** If you also run Claude outside the sandbox, set `CLAUDE_CONFIG_DIR=$HOME/.claude` globally too, otherwise the two will use different config locations and diverge.

</details>

### Network restrictions

`allowedDomains` controls internet/domain access. It does not allow host-local TCP ports.

By default, internet access is unrestricted and host-local services — databases, dev servers, SSH agent, Docker socket, etc. — are blocked. To restrict internet access, set `allowedDomains` — the sandbox can then only reach the domains you list. Leave it unset for open internet, or set it to `[ ]` to block all internet access.

`allowedDomains` accepts two formats:

- Attrset (recommended): map each domain to `"*"` (all HTTP methods allowed) or a list of permitted methods (e.g. `[ "GET" "HEAD" ]`).
- List: `[ "anthropic.com" "sentry.io" ]` — equivalent to allowing all methods for each domain.

Domains are suffix-matched, so `"anthropic.com"` will capture all `*.anthropic.com` subdomains.

When `allowedDomains` is set, all HTTP/HTTPS traffic is routed through a filtering proxy that inspects requests by domain and HTTP method. The sandbox cannot bypass the proxy and DNS resolution is blocked. WebSocket connections are not permitted.

Use `allowedLocalPorts` when the sandbox must reach trusted host-local TCP services, which are still blocked even when `allowedDomains` is set.

```nix
allowedLocalPorts = [ 3000 5432 ];
```

Set `allowedLocalPorts = null;` to allow all host-local TCP ports. Keep explicit port lists as narrow as possible; broad access can expose host-local services.

Blocked requests are logged to `/tmp/sandbox-proxy.log`. See [Git](#git) for limitations on SSH-based remotes.

## Authentication

Because `$HOME` is masked, agents cannot reach your system keychain, browser sessions, or SSH keys. The recommended approach is to authenticate via environment variable. Interactive login flows (e.g. `claude /login`, `gh auth login`) may not work inside the sandbox.

### Environment variable tokens (recommended)

Export your token in the host terminal before launching the sandbox — tokens are evaluated at runtime to prevent them from leaking into the Nix store:

```
# Claude Code
export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"

# GitHub Copilot CLI
export GITHUB_TOKEN="<your_token_here>"
```

Pass the variable reference (not the value) into `env`:

```nix
env = {
  CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
  ...
};
```

Alternatively, if you store your secret in a file (for example if you use sops), you can set a command that will read the secret at runtime:

```nix
env = {
  CLAUDE_CODE_OAUTH_TOKEN = "$(${pkgs.coreutils}/bin/cat /run/secrets/claude-code-oauth-token)";
  ...
};
```

### Credential files via `rwDirs`

If your agent stores credentials in files (e.g. Claude Code uses `~/.claude/`), you can run the login flow unsandboxed first, then expose the credential directory via `rwDirs`. The sandboxed agent will pick up the cached credentials.

<details>
<summary><strong>On macOS you will need to export the credentials from the Keychain first</strong></summary>

On macOS, Claude Code stores credentials in the system Keychain rather than in files. Since the sandbox cannot access the Keychain, the environment variable approach above is the simplest option.

If you can't use an environment variable token, you can export the Keychain credentials to a file that the sandbox can read:

```bash
# First Log in outside the sandbox first
claude /login
```

```bash
# Then export credentials from Keychain to a file the sandbox can read
security dump-keychain 2>&1 \
  | grep -o 'Claude Code-credentials[^"]*' \
  | sort -u \
  | while read entry; do
      security find-generic-password -a "$USER" -s "$entry" -w 2>/dev/null
    done \
  | python3 -c "
import sys, json
most_recent = None
for line in sys.stdin:
    try:
        creds = json.loads(line.strip())
        exp = creds.get('claudeAiOauth', {}).get('expiresAt', 0)
        if most_recent is None or exp > most_recent[1]:
            most_recent = (line.strip(), exp)
    except: pass
if most_recent: print(most_recent[0])
" > ~/.claude/.credentials.json
```

This finds all Claude Code credential entries in the Keychain and exports the one with the most recent expiry.

Then expose `~/.claude` via `rwDirs`. The sandboxed agent will read credentials from `~/.claude/.credentials.json` when Keychain access is unavailable.

Note: OAuth access tokens expire. You will need to re-run the export command periodically to refresh the credentials file.

</details>

### Tested agents

`claude-code` and `copilot-cli`. Other agents should work as long as they support token-based auth via an environment variable.

## Git

The sandbox allows access to the local git directory, including from within worktrees. Switching branches, reading history and other local operations work without any extra configuration. Committing requires a declared git identity — see [Git identity](#git-identity).

### Remote access (push / pull / fetch)

Interacting with remotes requires authentication. The recommended approach is to use HTTPS rather than SSH based remotes. The simplest way to authenticate is by passing a token via `env` (e.g. `GITHUB_TOKEN`), but you can also configure a [git credential helper](https://git-scm.com/doc/credential-helpers) to store your token for reuse so you don't have to pass it via environment variable.

SSH based remotes (e.g. `git@github.com:...`) won't work by default — SSH keys are not accessible because `$HOME` is masked, and when `allowedDomains` is set the proxy only handles HTTP/HTTPS so SSH traffic is blocked entirely. You can expose your SSH directory via `rwDirs` (e.g. `$HOME/.ssh`) and leave `allowedDomains` unset (open network) to enable SSH based git remotes, but this is not recommended.

### Git identity

`$HOME` is masked inside the sandbox, so your global gitconfig is not visible and git's `user.name` / `user.email` are unset. The sandbox never fabricates an identity if none are provided. This means `git commit` without a declared identity fails loudly (`fatal: ... auto-detection is disabled`).

To get correctly-attributed commits, declare a real identity in one of two ways:

- **Bind your host gitconfig read-only via `roFiles`** (recommended). Set your identity on the host (`git config --global user.name "..."; git config --global user.email "..."`), then add:

  ```nix
      roFiles = [ "$HOME/.config/git/config" ];  # or "$HOME/.gitconfig"
  ```

  git reads `[user]` through its normal global-config lookup. Because the file is read-only inside the sandbox, the agent can't set `core.hooksPath`, `core.fsmonitor`, or `alias.*` entries that would otherwise fire host code on the next host `git` invocation.

- **Via `env`** (fully self-contained, useful when you can't bind a host file):

  ```nix
      env = {
        GIT_AUTHOR_NAME = "Your Name";
        GIT_AUTHOR_EMAIL = "you@example.com";
        GIT_COMMITTER_NAME = "Your Name";
        GIT_COMMITTER_EMAIL = "you@example.com";
      };
  ```

> **Note:** do not run `git config --global ...` inside the sandbox — `$HOME` is an ephemeral tmpfs there, so it won't persist. Set your identity on the host and bind it, or use `env`.

## Using Nix inside the sandbox

Set `allowNix = true` to let the agent invoke nix commands from inside the sandbox. The agent is given access to the host's nix daemon and the full nix store. `pkgs.nix` is added to the agent's PATH automatically — you don't need to put it in `allowedPackages`.

What you need to configure:

- **Flake CLI features:** Your nix config is not visibile inside the sandbox. Either bind it via `roFiles = [ "/etc/nix/nix.conf" ]` to inherit your whole config or set `env.NIX_CONFIG = "experimental-features = nix-command flakes"` to enable just the flake CLI.

- **Nix state directories:** The client caches the flake registry and downloaded tarballs under `$HOME/.cache/nix`, writes registry overrides to `$HOME/.config/nix`, and stores per-user profiles under `$HOME/.local/share/nix`. Add these to `rwDirs` if you want any of that to persist across invocations.

- **Allowed domains:** When `allowedDomains` is set, the nix client itself needs `channels.nixos.org` , `github.com` + `raw.githubusercontent.com` , and `cache.nixos.org` to reliably fetch packages and flakes.

A complete example is at [`shells/claude-nix.shell.nix`](shells/claude-nix.shell.nix).

> **Security note:** `allowNix = true` weakens the security posture of the sandbox. The full Nix store is exposed and any executable in the nix store can be run by the agent — `allowedPackages` no longer restricts what the agent can *execute*, only what's on `PATH`. The `nix-daemon` runs outside the sandbox, so its own network activity — downloads of prebuilt packages from the caches it's configured to use — bypasses `allowedDomains`.

## Common Patterns / Recipes

### Python with uv

uv needs access to its cache dirs via `rwDirs`, otherwise it will re-download dependencies on every invocation. On NixOS, pre-compiled wheels will also fail to find glibc unless you thread `LD_LIBRARY_PATH` through from the host and use a nix-managed Python instead of a uv-managed one. See [`shells/claude-uv.shell.nix`](shells/claude-uv.shell.nix) for the full setup.

### Node.js with npm

For Node, you can simply add the npm cache as a `rwDir`.

```nix
allowedPackages = [ pkgs.nodejs pkgs.npm ];
rwDirs = [ "$HOME/.npm" ]; # Allow npm cache
```

## Troubleshooting

### Filesystem access issues

If the agent fails to perform a tool call, or file read/write, the sandbox is likely blocking a path that needs to be added to `rwDirs` / `rwFiles` (or `roDirs` / `roFiles` for read-only access).

The easiest way to explore the sandbox environment is to wrap `bash` itself with the same config as your agent and poke around interactively.

```nix
# mirror your agent's config
bash-sandboxed = sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "bash-sandboxed";
  allowedPackages = [ pkgs.coreutils ];
  rwDirs = [ "$HOME/.claude" ];
  rwFiles = [];
  allowedDomains = { "httpbin.org" = "*"; };
};
```

Running `bash-sandboxed` drops you into a shell with exactly the same filesystem view and restrictions your agent will see. Try:

```bash
touch /tmp/test && rm /tmp/test   # /tmp should be writable
curl https://example.com          # depends on your allowedDomains setting
which git                         # allowedPackages should be on PATH
ls /some/other/path               # should fail — confirming sandbox is active
cat ~/.ssh/id_ed25519             # should fail - shouldn't be able to read unspecified files in $HOME
ls $HOME                          # empty dir with symlinks to rwDirs
touch $HOME/.test && rm $HOME/.test  # writes allowed (but ephemeral)
ls $HOME/.claude                  # should work if in rwDirs (symlinked)
curl https://httpbin.org/get      # allowed domain — should work
curl https://example.com          # blocked domain — should fail
```

See [`debug/bash.shell.nix`](debug/bash.shell.nix) for a ready-to-use template (has `allowedDomains` set to `httpbin.org` for testing).

### Network access issues

If you've set `allowedDomains` and requests are failing, check which domains are being blocked:

```bash
tail -f /tmp/sandbox-proxy.log
```

You may need to add them to `allowedDomains`.

### macOS: unexpected sandbox denials

After a failure, you can query the system log for sandbox denials:

```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```

If something is blocked that should have been allowed by your sandbox config, this log can show which path or operation `sandbox-exec` denied.

### macOS: localhost service denials

On macOS, `sandbox-exec` shares localhost with the host and cannot distinguish a service started inside the sandbox from a host-local service. If a sandboxed process needs to call another sandboxed process on `localhost:<port>`, that port must be listed in `allowedLocalPorts` or all host-local ports must be allowed with `allowedLocalPorts = null;`. The same access also allows host-local services on those ports, so keep explicit lists narrow.

If you are unable to debug, or suspect the AI can't access a file or folder it should have access to by default, please raise an issue.

## Security

This section explains what the sandbox is and isn't designed to protect against, so you can decide whether it fits your situation.

### What it protects against

If the agent does something it shouldn't — runs a bad prompt, processes a malicious file, picks up a compromised dependency, or hallucinates a destructive command — the sandbox stops the damage from spreading outside the project directory. Concretely:

- It can't read your SSH keys, browser sessions, password manager, other projects' source code, or anything else in your home directory outside the paths you explicitly expose.
- It can't delete or modify files outside the project directory and your declared `rwDirs` / `rwFiles`.
- It can't reach the internet outside the domains you allow (when `allowedDomains` is set).
- It can't talk to local services on your laptop — databases, dev servers, the SSH agent, other terminal windows, etc. — unless you explicitly allow host-local TCP ports with `allowedLocalPorts`.
- It can only run the tools you list in `allowedPackages`.
- It can't see your other running programs, read environment variables they have set, or interfere with other terminals you have open.

### What it doesn't protect against

The sandbox is an **isolation** boundary, not an **anonymity** boundary, and not a defense against an attacker who has already taken over your machine in some other way.

- The agent can fingerprint your machine. It can see your hostname, hardware model, CPU, RAM, OS version, and rough network details. If you need the agent to *not know which machine it's running on*, this isn't the tool — you want a VM or a separate device.
- Anything you hand the agent, it has. If you expose your `~/.claude` directory (or any credential file) via `rwDirs`, or pass a token through `env`, the agent can read it — that's how it logs in. A compromised agent has the same access to those credentials as your shell does. Treat this the way you'd treat handing the token to any other CLI tool you didn't write yourself.
- The agent can edit its own sandbox config. `flake.nix` lives inside the project directory and is writable from inside the sandbox. An agent could weaken its own restrictions for the *next* session. Changes don't take effect until you re-enter the dev shell, so it's worth reviewing `git diff` before you do.
- No defense against root or kernel bugs. If something on your machine has already gained administrator-level access, or there's a deeper bug in the operating system itself, this sandbox can't stop it.

### Specific things worth being aware of

- Your username and home directory path are visible to the agent. This is unavoidable — the agent needs to know where `$HOME/.claude` resolves to. If your username is itself sensitive, this isn't the right tool.
- All of `/nix/store` is readable, not just your allowed packages. Only execution is restricted to your allowlist. The Nix store is normally world-readable on any system, so this matches existing behavior, but it does mean the agent can list every package you've built.
- `/tmp` is shared with the host. The agent can see (but not connect to) sockets and files other programs leave there. Don't put secrets in `/tmp` while the sandbox is running.

### Linux vs macOS

Both platforms enforce the same default protections. The one practical difference is localhost: on Linux, bubblewrap gives the sandbox its own network namespace, so services started inside the sandbox can reach each other on any localhost port freely. On macOS, `sandbox-exec` shares localhost with the host, so sandbox-internal localhost communication requires the port to be listed in `allowedLocalPorts` or all host-local ports to be allowed with `allowedLocalPorts = null;` — the same access also opens those host-local ports.

### Is this the right tool for me?

If your threat model is *"I want my AI agent to not accidentally destroy my work, leak my private files, or talk to random places on the internet,"* this sandbox is a good fit.

If your threat model is *"I assume the agent is actively malicious and need it to be unable to identify my specific machine or my real user account,"* you'll want a VM with a throwaway user account or a separate machine.

## Caveats

- `sandbox-exec` is deprecated on macOS. It remains the only native unprivileged sandboxing mechanism and currently works on macOS 26 (Tahoe) and older, but may break in a future release.
- Symlinks inside `rwDirs`, `rwFiles`, `roDirs`, and `roFiles` are only followed to already-permitted paths. A symlink is usable only if its target is the Nix store, the working directory, the Git directory, or another declared bind. Anything else is blocked — this prevents an agent from planting a symlink during a session to expand its own sandbox on the next startup (e.g. `~/.claude/evil -> /etc/shadow`). To expose a non-permitted path that's currently reached via a symlink, declare it explicitly as a `rwDir` / `rwFile` / `roDir` / `roFile`. Symlinks into the Nix store are read-only.
- Tested on x86_64-linux and aarch64-darwin. Other architectures should work but are untested.

## Similar projects

There are several other tools for sandboxing AI agents. Here are a few:

[Anthropic sandbox-runtime (srt)](https://github.com/anthropic-experimental/sandbox-runtime/tree/main) — An npm package that also uses bubblewrap on Linux and sandbox-exec on Macos.

[jail.nix](https://git.sr.ht/~alexdavid/jail.nix) — A nix library for building bubblewrap sandboxes. It's not built to be agent-specific but can be used for agent sandboxing. Linux only.

[jailed-agents](https://github.com/andersonjoseph/jailed-agents) — A nix library that provides pre-configured per-agent sandboxes using bubblewrap. Linux only.

[agent-box](https://github.com/fletchgqc/agentbox) — A rust CLI that uses disposable containers with Jujutsu or Git worktrees. MacOS and Linux.

[ai-jail](https://github.com/akitaonrails/ai-jail) — A Rust CLI that sandboxes agents using bubblewrap (with Landlock and seccomp) on Linux and sandbox-exec on macOS. Configured via a TOML file in the project directory.
