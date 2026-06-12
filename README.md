# agent-sandbox.nix

Lightweight and declarative sandboxing for AI agents on Linux and macOS.

Prevent your agents in YOLO mode from deleting your $HOME, force pushing to main, or publishing your ssh keys on reddit. Works with any CLI-based AI agent.

The sandbox uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux and sandbox-exec on macOS.

Tested with Claude's frontier models — see [Security](#security) for the threat model and known limits.

<details>
<summary><strong>V0.x -> V1.x Migration guide</strong></summary>
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

</details>

## What the sandbox allows

- **Project directory** — read/write access to the directory you launch the agent from.
- **Declared state** — read/write access to anything you list in `rwDirs` or `rwFiles`.
- **Allowed packages** — the binaries you list in `allowedPackages` are on the agent's PATH (plus `bash` and `cacert`).
- **Network** — unrestricted by default. Set `allowedDomains` to limit the agent to specific domains (and, optionally, specific HTTP methods).
- **Environment** — only variables you pass via `env` reach the agent; the host environment is otherwise cleared.
- **Git** — the repo's `.git` directory is exposed, including when it sits outside the project tree (worktrees).

Everything else is denied. `$HOME` is an ephemeral writable tmpfs that disappears when the sandbox exits.

## Usage

The quickest way to get started is with a flake template. If you prefer a `shell.nix`, see [`shells/`](shells/) for ready-to-use examples. Authentication is covered [below](#authentication).

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
| `env` | no | Additional environment variables as an attrset |
| `allowedDomains` | no | Limits which domains the sandbox can reach. Leave unset for open internet. Accepts a list of domains (all methods allowed), or an attrset mapping each domain to `"*"` or a list of HTTP methods. `[ ]` blocks all internet access. |

A minimal example — the arguments are the same whether you use a flake or a `shell.nix`:

```nix
mkSandbox {
  pkg = pkgs.claude-code;
  binName = "claude";
  outName = "claude-sandboxed";
  allowedPackages = [ pkgs.coreutils pkgs.git pkgs.ripgrep ];
  rwDirs = [ "$HOME/.claude" ];
  rwFiles = [ ];
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

By default, network access is unrestricted. To restrict it, set `allowedDomains` — the sandbox can then only reach the domains you list. Leave it unset for open internet, or set it to `[ ]` to block all network access.

`allowedDomains` accepts two formats:

- Attrset (recommended): map each domain to `"*"` (all HTTP methods allowed) or a list of permitted methods (e.g. `[ "GET" "HEAD" ]`).
- List: `[ "anthropic.com" "sentry.io" ]` — equivalent to allowing all methods for each domain.

Domains are suffix-matched, so `"anthropic.com"` will capture all `*.anthropic.com` subdomains.

When `allowedDomains` is set, all HTTP/HTTPS traffic is routed through a filtering proxy that inspects requests by domain and HTTP method. The sandbox cannot bypass the proxy and DNS resolution is blocked. WebSocket connections are not permitted.

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

The sandbox allows access to the local git directory, including from within worktrees. Committing, switching branches and other local operations are allowed without any extra configuration.

### Remote access (push / pull / fetch)

Interacting with remotes requires authentication. The recommended approach is to use HTTPS rather than SSH based remotes. The simplest way to authenticate is by passing a token via `env` (e.g. `GITHUB_TOKEN`), but you can also configure a [git credential helper](https://git-scm.com/doc/credential-helpers) to store your token for reuse so you don't have to pass it via environment variable.

SSH based remotes (e.g. `git@github.com:...`) won't work by default — SSH keys are not accessible because `$HOME` is masked, and when `allowedDomains` is set the proxy only handles HTTP/HTTPS so SSH traffic is blocked entirely. You can expose your SSH directory via `rwDirs` (e.g. `$HOME/.ssh`) and leave `allowedDomains` unset (open network) to enable SSH based git remotes, but this is not recommended.

### Git identity

To give the agent its own git identity, pass the following environment variables via `env`:

```nix
    env = {
      ...
      GIT_AUTHOR_NAME = "claude";
      GIT_AUTHOR_EMAIL = "claude@localhost";
      GIT_COMMITTER_NAME = "claude";
      GIT_COMMITTER_EMAIL = "claude@localhost";
    };
```

> **Note:** `.git/config` is read-only inside the sandbox, so `git config` commands run by the agent will not persist. Use `env` (as above) or configure git on the host before entering the sandbox.

## Common Patterns / Recipes

### Python with uv

uv needs access to its cache dirs via `rwDirs`, otherwise it will re-download dependencies on every invocation. On NixOS, pre-compiled wheels will also fail to find glibc unless you thread `LD_LIBRARY_PATH` through from the host and use a nix-managed Python instead of a uv-managed one. See [`shells/claude-uv.shell.nix`](shells/claude-uv.shell.nix) for the full setup.

### Node.js with npm

For Node, you can simply add the npm cache as a `rwDir`.

```nix
allowedPackages = [ pkgs.nodejs pkgs.npm ];
rwDirs = [ "$HOME/.npm" ]; # Allow npm cache
```

## Debugging

If the agent fails to perform a tool call, or file read/write, the sandbox is likely blocking a path that needs to be added to `rwDirs` or `rwFiles`.

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

**Network issues:** If you've set `allowedDomains` and requests are failing, check which domains are being blocked:

```bash
tail -f /tmp/sandbox-proxy.log
```

You may need to add them to `allowedDomains`.

**macOS:** after a failure, you can query the system log for sandbox denials:

```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```

If you are unable to debug, or suspect the AI can't access a file or folder it should have access to by default, please raise an issue.

## Security

This section explains what the sandbox is and isn't designed to protect against, so you can decide whether it fits your situation.

### What it protects against

If the agent does something it shouldn't — runs a bad prompt, processes a malicious file, picks up a compromised dependency, or hallucinates a destructive command — the sandbox stops the damage from spreading outside the project directory. Concretely:

- It can't read your SSH keys, browser sessions, password manager, other projects' source code, or anything else in your home directory outside the paths you explicitly expose.
- It can't delete or modify files outside the project directory and your declared `rwDirs` / `rwFiles`.
- It can't reach the internet outside the domains you allow (when `allowedDomains` is set).
- It can't talk to local services on your laptop — databases, dev servers, the SSH agent, other terminal windows, etc.
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

Both platforms enforce the same protections — everything in the list above holds equally on Linux and macOS. The mechanisms differ (bubblewrap and pasta on Linux, `sandbox-exec` on macOS), and the specific bits of information an agent can learn about your machine vary a little, but the practical end state is the same on both.

### Is this the right tool for me?

If your threat model is *"I want my AI agent to not accidentally destroy my work, leak my private files, or talk to random places on the internet,"* this sandbox is a good fit.

If your threat model is *"I assume the agent is actively malicious and need it to be unable to identify my specific machine or my real user account,"* you'll want a VM with a throwaway user account or a separate machine.

## Caveats

- `sandbox-exec` is deprecated on macOS. It remains the only native unprivileged sandboxing mechanism and currently works on macOS 26 (Tahoe) and older, but may break in a future release.
- Symlinks inside `rwDirs` and `rwFiles` are only followed to already-permitted paths. A symlink is usable only if its target is the Nix store, the working directory, the Git directory, or another declared `rwDir`/`rwFile`. Anything else is blocked — this prevents an agent from planting a symlink during a session to expand its own sandbox on the next startup (e.g. `~/.claude/evil -> /etc/shadow`). To expose a non-permitted path that's currently reached via a symlink, declare it explicitly as a `rwDir` or `rwFile`. Symlinks into the Nix store are read-only. Platform differences: on Linux, only top-level symlinks inside a `rwDir` are detected (the startup scan is one level deep) and blocked targets produce a `sandbox: WARNING` line on startup; on macOS, symlinks are followed at any depth and denials happen at runtime — check `log show --predicate 'eventMessage CONTAINS "deny"'`.
- Tested on x86_64-linux and aarch64-darwin. Other architectures should work but are untested.

## Similar projects

There are several other tools for sandboxing AI agents. Here are a few:

[Anthropic sandbox-runtime (srt)](https://github.com/anthropic-experimental/sandbox-runtime/tree/main) — An npm package that also uses bubblewrap on Linux and sandbox-exec on Macos.

[jail.nix](https://git.sr.ht/~alexdavid/jail.nix) — A nix library for building bubblewrap sandboxes. It's not built to be agent-specific but can be used for agent sandboxing. Linux only.

[jailed-agents](https://github.com/andersonjoseph/jailed-agents) — A nix library that provides pre-configured per-agent sandboxes using bubblewrap. Linux only.

[agent-box](https://github.com/fletchgqc/agentbox) — A rust CLI that uses disposable containers with Jujutsu or Git worktrees. MacOS and Linux.

[ai-jail](https://github.com/akitaonrails/ai-jail) — A Rust CLI that sandboxes agents using bubblewrap (with Landlock and seccomp) on Linux and sandbox-exec on macOS. Configured via a TOML file in the project directory.
