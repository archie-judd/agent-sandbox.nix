# agent-sandbox.nix

Lightweight and declarative sandboxing for AI coding agents on Linux (bubblewrap) and macOS (Seatbelt).

Prevents agents in YOLO mode from reading your dotfiles, deleting your home directory, or touching anything outside the project. Network access is left open for API calls.

## What the sandbox allows

- Read/write the current working directory
- Read/write explicitly declared state dirs and files
- Network access (unrestricted)
- Binaries from `allowedPackages`
- `/nix/store` (read-only), `/tmp` (ephemeral), local git repo access (commits allowed; `git push` is blocked)

Everything else is denied. `$HOME` is either an empty tmpfs (Linux) or inaccessible (macOS).

## Authentication

Because `$HOME` is masked, agents cannot reach your system keychain, browser sessions, or SSH keys. **Interactive login flows (e.g. `claude /login`, `gh auth login`) will not work inside the sandbox.** You must authenticate via an environment variable token instead.

Export your token in the host terminal before launching the sandbox — tokens are evaluated at runtime to prevent them from leaking into the world-readable Nix store:

```bash
# Claude Code
export CLAUDE_CODE_OAUTH_TOKEN="your_token_here"

# GitHub Copilot CLI
export GITHUB_TOKEN="your_token_here"

```

Pass the variable reference (not the value) into `extraEnv`:

```nix
extraEnv = {
  CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
  ...
};
```

Alternatively, if you use sops, you can inject the secret at build time:

```nix
extraEnv = {
  CLAUDE_CODE_OAUTH_TOKEN = "$(${pkgs.coreutils}/bin/cat /run/secrets/claude-code-oauth-token)" # or wherever your sops secrets directory is
  ...
};
```

> **Tested agents:** `claude-code` and `copilot-cli`. Other agents should work as long as they support token-based auth via an environment variable.

> **Warning:** Git pushes are also blocked as a side effect of masking `$HOME` — the agent has no access to your `~/.ssh` keys. The only exception is if you have a plaintext access token hardcoded directly into your project's `.git/config` remote URL, or if you explicitly pass `GITHUB_TOKEN` in `extraEnv`.

## Usage

### In a flake

```nix
{
  inputs.sandbox.url = "github:archie-judd/agent-sandbox.nix";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, sandbox, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { system = system; };
        in {
          claude-sandboxed = sandbox.lib.${system}.mkSandbox {
            pkg = pkgs.claude-code;
            binName = "claude";
            outName = "claude-sandboxed";
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
            stateFiles = [ "$HOME/.claude.json" ];
            extraEnv = {
              CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
              # Give the agent its own git identity so its commits are distinguishable from yours
              GIT_AUTHOR_NAME = "claude-agent";
              GIT_AUTHOR_EMAIL = "claude-agent@localhost";
              GIT_COMMITTER_NAME = "claude-agent";
              GIT_COMMITTER_EMAIL = "claude-agent@localhost";
            };
          };
        });
    };
}
```

See `checks` in `flake.nix` for a minimal working example that is evaluated by `nix flake check`.

### In a shell.nix

See [`examples/claude.shell.nix`](examples/claude.shell.nix) for a ready-to-use template. Copy it into your project and adjust as needed.

## Arguments

| Argument | Required | Description |
|---|---|---|
| `pkg` | yes | Package containing the binary to wrap |
| `binName` | yes | Name of the binary inside `pkg/bin/` |
| `outName` | yes | Name for the resulting wrapped binary |
| `allowedPackages` | yes | Packages whose `bin/` dirs form the sandbox PATH |
| `stateDirs` | no | Directories the agent can read/write (e.g. `~/.config/claude`) |
| `stateFiles` | no | Individual files the agent can read/write |
| `extraEnv` | no | Additional environment variables as an attrset |

## Common Patterns / Recipes

Because the sandbox blocks access to your home directory, tools that rely on global caches, configuration files, or auth states will fail (EACCES or ENOENT) unless explicitly permitted in `stateDirs` or `stateFiles`.

### Python with uv

uv needs access to its cache dirs via `stateDirs`, otherwise it will re-download dependencies on every invocation. On NixOS, pre-compiled wheels will also fail to find glibc unless you thread `LD_LIBRARY_PATH` through from the host and use a nix-managed Python instead of a uv-managed one. See [`examples/claude-uv.shell.nix`](examples/claude-uv.shell.nix) for the full setup.

### Node.js with npm

```nix
allowedPackages = [ pkgs.nodejs pkgs.npm ];
stateDirs = [ "$HOME/.npm" ]; # Allow npm cache
```

## Debugging

If the agent fails with `EACCES` or `ENOENT`, the sandbox is likely blocking a path that needs to be added to `stateDirs` or `stateFiles`.

**Both platforms:** the easiest way to explore the sandbox environment is to wrap `bash` itself with the same config as your agent and poke around interactively:

```nix
bash-sandboxed = sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "bash-sandboxed";
  allowedPackages = [ pkgs.coreutils pkgs.bash ];
  stateDirs = [ "$HOME/.claude" ];  # mirror your agent's config
  stateFiles = [ "$HOME/.claude.json" ];
};
```

Running `bash-sandboxed` drops you into a shell with exactly the same filesystem view and restrictions your agent will see. Try:

```bash
ls $HOME                   # should show only your stateDirs
cat $HOME/.claude.json     # should work if in stateFiles
ls /tmp                    # should be writable scratch space
curl https://example.com   # network should be open
which git                  # check allowedPackages are visible
ls /some/other/path        # should fail — confirming the sandbox is active
```

See [`debug/bash.shell.nix`](debug/bash.shell.nix) for a ready-to-use template.

**Linux:** if you're still stuck, look at the error the agent reports — the path in the message is usually enough to identify the missing `stateDirs` or `stateFiles` entry. Paste your config and the error into an AI.

**macOS:** after a failure, query the system log for sandbox denials:
```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```
Each entry shows the denied operation and path, telling you exactly which `stateDirs` or `stateFiles` entry is missing.

## Platform notes

**Linux:** Uses bubblewrap to build a temporary, isolated environment. The agent is completely cut off from the host machine (unsharing PID, user, IPC, UTS, and cgroup namespaces) and cannot see your host processes.

**macOS:** Uses `sandbox-exec` (Seatbelt) to enforce a strict "deny-default" security policy.

## Caveats

- **The network is fully open.** A compromised agent can exfiltrate any file it *can* read to a remote server.
- **`sandbox-exec` is deprecated on macOS.** It remains the only native unprivileged sandboxing mechanism and currently works on macOS 15 (Sequoia) and older, but may break in a future release.
- **State directories dictate your safety.** The sandbox is only as safe as what you pass into `stateDirs`. Never add `$HOME`.
- See the comments in `default.nix` for detailed debugging tips for each platform.
