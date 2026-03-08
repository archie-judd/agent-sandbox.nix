# agent-sandbox.nix

Lightweight and declarative sandboxing for AI agents on Linux and macOS.

Prevent your agents in YOLO mode from reading your dotfiles, accessing your SSH keys, deleting your $HOME or touching anything outside of the project.  Works with any CLI-based AI agent — Claude Code, Aider, GitHub Copilot CLI, and others. Network access is left unrestricted for API calls.

The sandbox uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux and sandbox-exec on macOS.

## What the sandbox allows

- Read/write the current working directory
- Read/write explicitly declared state dirs and files
- Network access (unrestricted)
- Binaries from `allowedPackages`
- `/nix/store` (read-only), `/tmp` (ephemeral), local git repo access (commits allowed; `git push` is blocked)

Everything else is denied. `$HOME` is either an empty writable tmpfs (Linux) or read-only (macOS).

## Usage

See [`examples/`](examples/) for ready-to-use templates. Authentication is covered [below](#authentication).

### In a flake

Here is an example flake that provides a development shell with a sandboxed claude binary.

```nix
{
  inputs.sandbox.url = "github:archie-judd/agent-sandbox.nix";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, sandbox, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { system = system; };
          claude-sandboxed = sandbox.lib.${system}.mkSandbox {
            pkg = pkgs.claude-code;
            binName = "claude";
            outName = "claude-sandboxed"; # or whatever alias you'd like
            allowedPackages = [
              pkgs.coreutils
              pkgs.bash
              pkgs.git
              pkgs.ripgrep
              pkgs.fd
              pkgs.gnused
              pkgs.gnugrep
              pkgs.findutils
              pkgs.jq
            ];
            stateDirs = [ "$HOME/.claude" ];
            stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
            extraEnv = {
              # Use literal strings for secrets to evaluate at runtime!
              # builtins.getEnv will leak your token into the /nix/store.
              CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
              # optionally provide the agent with a git identity to differentiate its commits from yours
              GIT_AUTHOR_NAME = "claude-agent";
              GIT_AUTHOR_EMAIL = "claude-agent@localhost";
              GIT_COMMITTER_NAME = "claude-agent";
              GIT_COMMITTER_EMAIL = "claude-agent@localhost";
            };
          };
        in {
          default = pkgs.mkShell {
            packages = [ claude-sandboxed ];
          };
        });
    };
}
```

> Note: claude and most other AI CLI tools are not FOSS. You will need to set `NIXPKGS_ALLOW_UNFREE=1` and invoke the shell with `--impure`:
> ```bash
> NIXPKGS_ALLOW_UNFREE=1 nix develop --impure
> ```

### In a shell.nix

Provides a nix shell with a sandboxed claude binary:

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
    outName = "claude-sandboxed"; # or whatever alias you'd like
    allowedPackages = [
      pkgs.coreutils
      pkgs.bash
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
      pkgs.gnused
      pkgs.gnugrep
      pkgs.findutils
      pkgs.jq
    ];
    stateDirs = [ "$HOME/.claude" ];
    stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
    extraEnv = {
      # Use literal strings for secrets to evaluate at runtime!
      # builtins.getEnv will leak your token into the /nix/store.
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      # optionally provide the agent with a git identity to differentiate its commits from yours
      GIT_AUTHOR_NAME = "claude-agent";
      GIT_AUTHOR_EMAIL = "claude-agent@localhost";
      GIT_COMMITTER_NAME = "claude-agent";
      GIT_COMMITTER_EMAIL = "claude-agent@localhost";
    };
  };
in pkgs.mkShell { packages = [ claude-sandboxed ]; }
```

## Arguments

| Argument | Required | Description |
|---|---|---|
| `pkg` | yes | Package containing the binary to wrap |
| `binName` | yes | Name of the binary inside `pkg/bin/` |
| `outName` | yes | Name for the resulting wrapped binary and the command to invoke it with |
| `allowedPackages` | yes | Packages whose `bin/` dirs form the sandbox PATH |
| `stateDirs` | no | Directories the agent can read/write (e.g. `~/.config/claude`) |
| `stateFiles` | no | Individual files the agent can read/write |
| `extraEnv` | no | Additional environment variables as an attrset |


## Authentication

Because `$HOME` is masked, agents cannot reach your system keychain, browser sessions, or SSH keys. **Interactive login flows (e.g. `claude /login`, `gh auth login`) will not work inside the sandbox.** You must authenticate via an environment variable token instead.

Export your token in the host terminal before launching the sandbox — tokens are evaluated at runtime to prevent them from leaking into the world-readable Nix store:

```bash
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

Alternatively, if you store your secret in a file (for example if you use sops), you can set a command that will read the secret at runtime.

```nix
extraEnv = {
  CLAUDE_CODE_OAUTH_TOKEN = "$(${pkgs.coreutils}/bin/cat /run/secrets/claude-code-oauth-token)"; # or wherever your sops secrets directory is
  ...
};
```

> **Tested agents:** `claude-code` and `copilot-cli`. Other agents should work as long as they support token-based auth via an environment variable.

> **Warning:** Git pushes are also blocked as a side effect of masking `$HOME` — the agent has no access to your `~/.ssh` keys. The only exception is if you have a plaintext access token hardcoded directly into your project's `.git/config` remote URL, or if you explicitly pass `GITHUB_TOKEN` in `extraEnv`.

## Common Patterns / Recipes

Because the sandbox blocks access to your home directory, tools that rely on global caches, configuration files, or auth states will fail (EACCES or ENOENT) unless explicitly permitted in `stateDirs` or `stateFiles`.

### Python with uv

uv needs access to its cache dirs via `stateDirs`, otherwise it will re-download dependencies on every invocation. On NixOS, pre-compiled wheels will also fail to find glibc unless you thread `LD_LIBRARY_PATH` through from the host and use a nix-managed Python instead of a uv-managed one. See [`examples/claude-uv.shell.nix`](examples/claude-uv.shell.nix) for the full setup.

### Node.js with npm

For Node, you can simply add the npm cache as a state-dir.

```nix
allowedPackages = [ pkgs.nodejs pkgs.npm ];
stateDirs = [ "$HOME/.npm" ]; # Allow npm cache
```

## Debugging

If the agent fails to perform a tool call, or file read/write, the sandbox is likely blocking a path that needs to be added to `stateDirs` or `stateFiles`.

The easiest way to explore the sandbox environment is to wrap `bash` itself with the same config as your agent and poke around interactively:

```nix
bash-sandboxed = sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "bash-sandboxed";
  allowedPackages = [ pkgs.coreutils pkgs.bash ];
  stateDirs = [ "$HOME/.claude" ];  # mirror your agent's config
  stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
};
```

Running `bash-sandboxed` drops you into a shell with exactly the same filesystem view and restrictions your agent will see. Try:

```bash
# Platform-independent
touch /tmp/test && rm /tmp/test   # /tmp should be writable
curl https://example.com          # network should be open
which git                         # allowedPackages should be on PATH
ls /some/other/path               # should fail — confirming sandbox is active

# Linux: $HOME is an empty writable tmpfs (ephemeral, not persisted)
ls $HOME                          # empty directory
touch $HOME/.test && rm $HOME/.test  # writes allowed (but ephemeral)

# macOS: $HOME is readable but writes are blocked (except stateDirs/stateFiles)
ls $HOME                          # shows your real home contents (read-only)
touch $HOME/.test                 # should fail — writes blocked
echo test > $HOME/.claude.json    # should work if in stateFiles
ls $HOME/.claude                  # should work if in stateDirs
```

See [`debug/bash.shell.nix`](debug/bash.shell.nix) for a ready-to-use template.

**macOS:** after a failure, you can query the system log for sandbox denials:
```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```

If you are unable to debug, or suspect the AI can't access a file or folder it should have access to by default, please raise an issue.

## Platform notes

**Linux:** Uses bubblewrap to build a temporary, isolated environment. The agent is completely cut off from the host machine (unsharing PID, user, IPC, UTS, and cgroup namespaces) and cannot see your host processes.

**macOS:** Uses `sandbox-exec` to enforce a strict "deny-default" security policy.

## Caveats

- **The network is fully open.** A compromised agent can exfiltrate any file it *can* read to a remote server.
- **`sandbox-exec` is deprecated on macOS.** It remains the only native unprivileged sandboxing mechanism and currently works on macOS 26 (Tahoe) and older, but may break in a future release.
- **State directories dictate your safety.** The sandbox is only as safe as what you pass into `stateDirs`. Never add `$HOME`.
- See the comments in `default.nix` for detailed debugging tips for each platform.
- Tested on x86_64-linux and aarch64-darwin. Other architectures should work but are untested.
