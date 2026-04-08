# agent-sandbox.nix

Lightweight and declarative sandboxing for AI agents on Linux and macOS.

Prevent your agents in YOLO mode from deleting your $HOME, force pushing to main, or publishing your ssh keys on reddit. Works with any CLI-based AI agent.

The sandbox uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux and sandbox-exec on macOS.

## What the sandbox allows

- Read/write the working directory from which the sandboxed agent is invoked.
- Read/write explicitly declared state dirs and files.
- Execution of binaries from `allowedPackages`, plus bash, which is provided by default.
- Optionally restrict network access to particular domains and HTTP methods.
- Environment variables from extraEnv (host environment is cleared).
- Git (via the repository's .git directory), including from within worktrees.

Everything else is denied. `$HOME` is an ephemeral writable tmpfs on both platforms.

## Usage

Use a flake template or see [`shells/`](shells/) for ready-to-use shell.nix files. Authentication is covered [below](#authentication).

### Templates

Flake templates are provided for quick project setup:

| Template | Description |
|---|---|
| `claude` | Dev shell with a sandboxed Claude Code binary |
| `copilot` | Dev shell with a sandboxed GitHub Copilot CLI binary |

Initialize a template in your project directory:

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

> **Network Restrictions**: If you'd like to restrict network connections to particular domains, see [Network restrictions](#network-restrictions).

### In a shell.nix

You can also use a `shell.nix` instead of a flake. See [`shells/`](shells/) for ready-to-use templates.


Here is an example that provides a nix shell with a sandboxed Claude Code binary (see [`shells/claude.shell.nix`](shells/claude.shell.nix) for the full version):

```nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  sandbox = import (fetchTarball
    "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz") {
      pkgs = pkgs;
    };
  claude-sandboxed = sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    allowedPackages = [
      pkgs.coreutils
      pkgs.which
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
      pkgs.gnused
      pkgs.gnugrep
      pkgs.findutils
      pkgs.jq
    ]; # bash is allowed by default - it is required by the sandbox
    stateDirs = [ "$HOME/.claude" ];
    stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
    extraEnv = {
      # Pass secrets as shell variable references (e.g. "$TOKEN"), not
      # via builtins.getEnv, so they expand at runtime and stay out of
      # the /nix/store.
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
    };
    restrictNetwork = true;
    allowedDomains = {
      "anthropic.com" = "*";                          # all methods, including subdomains
      "claude.com" = "*";
      "raw.githubusercontent.com" = [ "GET" "HEAD" ]; # read-only
      "api.github.com" = [ "GET" "HEAD" ];
    };
  };
in pkgs.mkShell { packages = [ claude-sandboxed ]; }
```

Enter the dev shell with:

```bash
nix-shell shell.nix
```


## Arguments

| Argument | Required | Description |
|---|---|---|
| `pkg` | yes | Package containing the binary to wrap |
| `binName` | yes | Name of the binary inside `pkg/bin/` |
| `outName` | yes | Name for the resulting wrapped binary and the command to invoke it with |
| `allowedPackages` | yes | Packages whose `bin/` dirs form the sandbox PATH. `bash` and `cacert` are provided by default — the sandbox needs a shell to run, and `cacert` is required for HTTPS to work. |
| `stateDirs` | no | Directories the agent can read/write (e.g. `~/.config/claude`) |
| `stateFiles` | no | Individual files the agent can read/write |
| `extraEnv` | no | Additional environment variables as an attrset |
| `restrictNetwork` | no | When `true`, network is limited to `allowedDomains` (default `false`) |
| `allowedDomains` | no | Domains the sandbox can reach when `restrictNetwork = true`. Attrset mapping domains to `"*"` or a list of HTTP methods, or a list of domain strings (all methods allowed). |


### Network restrictions

By default, network access is unrestricted. But you can optionally restrict connections to specific domains by setting `restrictNetwork = true` and providing `allowedDomains` (as shown in the example above).

`allowedDomains` accepts two formats:

- **Attrset (recommended):** map each domain to `"*"` (all HTTP methods allowed) or a list of permitted methods (e.g. `[ "GET" "HEAD" ]`).
- **List:** `[ "anthropic.com" "sentry.io" ]` — equivalent to allowing all methods for each domain.

Domains are suffix-matched, so `"anthropic.com"` will capture all `*.anthropic.com` subdomains.

When `restrictNetwork = true`, all HTTP/HTTPS traffic is routed through a filtering proxy that inspects requests by domain and HTTP method. The sandbox cannot bypass the proxy and DNS resolution is blocked. WebSocket connections are not permitted.

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

Pass the variable reference (not the value) into `extraEnv`:

```nix
extraEnv = {
  CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
  ...
};
```

Alternatively, if you store your secret in a file (for example if you use sops), you can set a command that will read the secret at runtime:

```nix
extraEnv = {
  CLAUDE_CODE_OAUTH_TOKEN = "$(${pkgs.coreutils}/bin/cat /run/secrets/claude-code-oauth-token)";
  ...
};
```

### Credential files via `stateDirs`

If your agent stores credentials in files (e.g. Claude Code uses `~/.claude/`), you can run the login flow unsandboxed first, then expose the credential directory via `stateDirs`. The sandboxed agent will pick up the cached credentials.

<details>
<summary><strong>macOS Keychain workaround</strong></summary>

On macOS, Claude Code stores credentials in the system Keychain rather than in files. Since the sandbox cannot access the Keychain, the environment variable approach above is the simplest option.

If you can't use an environment variable token, you can export the Keychain credentials to a file that the sandbox can read:

```bash
# Log in outside the sandbox first
claude /login

# Export credentials from Keychain to a file the sandbox can read
security find-generic-password -a "$USER" -s "Claude Code-credentials" -w > ~/.claude/.credentials.json
```

Then expose `~/.claude` via `stateDirs`. The sandboxed agent will read credentials from `~/.claude/.credentials.json` when Keychain access is unavailable.

</details>

### Tested agents

`claude-code` and `copilot-cli`. Other agents should work as long as they support token-based auth via an environment variable.

## Git

The sandbox allows access to the local git directory, including from within worktrees. Committing, switching branches and other local operations are allowed without any extra configuration.

### Remote access (push / pull / fetch)

Interacting with remotes requires authentication. The recommended approach is to use HTTPS rather than SSH based remotes. The simplest way to authenticate is by passing a token via `extraEnv` (e.g. `GITHUB_TOKEN`), but you can also configure a [git credential helper](https://git-scm.com/doc/credential-helpers) to store your token for reuse so you don't have to pass it via environment variable.

SSH based remotes (e.g. `git@github.com:...`) won't work by default — SSH keys are not accessible because `$HOME` is masked, and when `restrictNetwork = true` the proxy only handles HTTP/HTTPS so SSH traffic is blocked entirely. You can expose your SSH directory via `stateDirs` (e.g. `$HOME/.ssh`) and set `restrictNetwork = false` to enable SSH based git remotes, but this is not recommended. 

### Git identity

To give the agent its own git identity, pass the following environment variables via `extraEnv`:

```nix
    extraEnv = {
      ...
      GIT_AUTHOR_NAME = "claude";
      GIT_AUTHOR_EMAIL = "claude@localhost";
      GIT_COMMITTER_NAME = "claude";
      GIT_COMMITTER_EMAIL = "claude@localhost";
    };
```

## Common Patterns / Recipes

### Python with uv

uv needs access to its cache dirs via `stateDirs`, otherwise it will re-download dependencies on every invocation. On NixOS, pre-compiled wheels will also fail to find glibc unless you thread `LD_LIBRARY_PATH` through from the host and use a nix-managed Python instead of a uv-managed one. See [`shells/claude-uv.shell.nix`](shells/claude-uv.shell.nix) for the full setup.

### Node.js with npm

For Node, you can simply add the npm cache as a `stateDir`.

```nix
allowedPackages = [ pkgs.nodejs pkgs.npm ];
stateDirs = [ "$HOME/.npm" ]; # Allow npm cache
```

## Debugging

If the agent fails to perform a tool call, or file read/write, the sandbox is likely blocking a path that needs to be added to `stateDirs` or `stateFiles`.

The easiest way to explore the sandbox environment is to wrap `bash` itself with the same config as your agent and poke around interactively:

```nix
# mirror your agent's config
bash-sandboxed = sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "bash-sandboxed";
  allowedPackages = [ pkgs.coreutils ];
  stateDirs = [ "$HOME/.claude" ];
  stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
  restrictNetwork = true;
  allowedDomains = { "httpbin.org" = "*"; };
};
```

Running `bash-sandboxed` drops you into a shell with exactly the same filesystem view and restrictions your agent will see. Try:

```bash
touch /tmp/test && rm /tmp/test   # /tmp should be writable
curl https://example.com          # depends on restrictNetwork setting
which git                         # allowedPackages should be on PATH
ls /some/other/path               # should fail — confirming sandbox is active
cat ~/.ssh/id_ed25519             # should fail - shouldn't be able to read unspecified files in $HOME
ls $HOME                          # empty dir with symlinks to stateDirs/stateFiles
touch $HOME/.test && rm $HOME/.test  # writes allowed (but ephemeral)
echo test > $HOME/.claude.json    # should work if in stateFiles (symlinked)
ls $HOME/.claude                  # should work if in stateDirs (symlinked)
curl https://httpbin.org/get      # allowed domain — should work
curl https://example.com          # blocked domain — should fail
```

See [`debug/bash.shell.nix`](debug/bash.shell.nix) for a ready-to-use template (has `restrictNetwork = true` with `httpbin.org` allowed for testing).

**Network issues:** If `restrictNetwork = true` and requests are failing, check which domains are being blocked:
```bash
tail -f /tmp/sandbox-proxy.log
```
You may need to add them to `allowedDomains`.

**macOS:** after a failure, you can query the system log for sandbox denials:
```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```

If you are unable to debug, or suspect the AI can't access a file or folder it should have access to by default, please raise an issue.

## Platform notes

**Linux:** Uses bubblewrap to build a temporary, isolated environment. The agent is completely cut off from the host machine (unsharing PID, user, IPC, UTS, and cgroup namespaces) and cannot see your host processes.

**macOS:** Uses `sandbox-exec` to enforce a strict "deny-default" security policy.

## Caveats

- **`sandbox-exec` is deprecated on macOS.** It remains the only native unprivileged sandboxing mechanism and currently works on macOS 26 (Tahoe) and older, but may break in a future release.
- **macOS only: symlinks inside `stateDirs` and `stateFiles` must point to already-allowed paths.** Seatbelt follows symlinks to their target — if the target isn't in the Nix store closure or another allowed path, access will be denied. Symlinks into the Nix store will work but are read-only.
- **Linux only: only top-level symlinks inside `stateDirs` are resolved.** At startup, the sandbox scans each `stateDir` for symlinks in its immediate children and binds their targets into the sandbox. Symlinks inside subdirectories are not followed. If you have deeper symlinks, add the target path as an additional `stateDir`.
- Tested on x86_64-linux and aarch64-darwin. Other architectures should work but are untested.

## Similar projects

There are several other tools for sandboxing AI agents. Here are a few:

[**Anthropic sandbox-runtime (srt)**](https://github.com/anthropic-experimental/sandbox-runtime/tree/main) — An npm package that also uses bubblewrap on Linux and sandbox-exec on Macos. 

[**jail.nix**](https://git.sr.ht/~alexdavid/jail.nix) — A nix library for building bubblewrap sandboxes. It's not built to be agent-specific but can be used for agent sandboxing. Linux only.

[**jailed-agents**](https://github.com/andersonjoseph/jailed-agents) — A nix library that provides pre-configured per-agent sandboxes using bubblewrap. Linux only. 

[**agent-box**](https://github.com/fletchgqc/agentbox) — A rust CLI that uses disposable containers with Jujutsu or Git worktrees. MacOS and Linux.

[**jjinn**](https://github.com/anglesideangle/jjinn) — A nix script that sandboxes agents in ephemeral Jujutsu workspaces using bubblewrap. Linux only.
