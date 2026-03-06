# agent-sandbox.nix

Lightweight sandboxing for AI coding agents on Linux (bubblewrap) and macOS (Seatbelt).

Prevents agents in YOLO mode from reading your dotfiles, deleting your home directory, or touching anything outside the project. Network access is left open for API calls.

## What the sandbox allows

- Read/write the current working directory
- Read/write explicitly declared state dirs and files
- Network access (unrestricted)
- Binaries from `allowedPackages` 
- `/nix/store` (read-only), `/tmp` (ephemeral), local git repo access (commits allowed; `git push` is blocked)

Everything else is denied. `$HOME` is either an empty tmpfs (Linux) or simply inaccessible (macOS).

## Usage

Add the flake as an input and call `mkSandbox`:

```nix
{
  inputs.sandbox.url = "github:you/sandbox.nix";
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
              # Pass the literal shell variable to evaluate at runtime, 
              # preventing API keys from leaking into the world-readable /nix/store
              CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
              GIT_AUTHOR_NAME = "claude-agent";
              GIT_AUTHOR_EMAIL = "claude-agent@localhost";
              GIT_COMMITTER_NAME = "claude-agent";
              GIT_COMMITTER_EMAIL = "claude-agent@localhost";
            };
        });
    };
}
```

See `checks` in `flake.nix` for a minimal working example that is evaluated by `nix flake check`.

For a standalone dev shell, see `example.shell.nix`.

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

## Platform notes

**Linux:** Uses bubblewrap to build a temporary, isolated environment. The agent is completely cut off from the host machine (unsharing PID, user, IPC, UTS, and cgroup namespaces) and cannot see your host processes.

**macOS:** Uses `sandbox-exec` (Seatbelt) to enforce a strict "deny-default" security policy. *Note: `sandbox-exec` is deprecated by Apple, but it remains the only native unprivileged sandboxing mechanism and works natively on macOS 26 (Tahoe) and older releases.*

## Caveats

- **The network is fully open.** A compromised agent can exfiltrate any file it *can* read to a remote server.
- **Git pushes are naturally blocked:** Because `$HOME` is masked, the agent has no access to your `~/.ssh` keys or system keychain. If the agent attempts a `git push`, it will fail authentication. **Warning:** The only exception is if you have a plaintext access token hardcoded directly into your project's `.git/config` remote URL, or if you explicitly pass `GITHUB_TOKEN` in `extraEnv`.
- **State directories dictate your safety:** The sandbox is only as safe as what you pass into `stateDirs`. Never add `$HOME`.
- See the comments in `sandbox.nix` for detailed debugging tips for each platform.
