# Example: a flake providing a dev shell with a sandboxed Claude Code binary.
# Copy this to your project root as flake.nix and adjust as needed.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   NIXPKGS_ALLOW_UNFREE=1 nix develop --impure
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
            outName = "claude-sandboxed";
            allowedPackages = [
              pkgs.coreutils
              pkgs.which
              pkgs.curl
              pkgs.bashNonInteractive
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
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              GIT_AUTHOR_NAME = "claude-agent";
              GIT_AUTHOR_EMAIL = "claude-agent@localhost";
              GIT_COMMITTER_NAME = "claude-agent";
              GIT_COMMITTER_EMAIL = "claude-agent@localhost";
            };
            restrictNetwork = true;
            allowedDomains = [
              # Anthropic
              "anthropic.com"
              "claude.com"
              # GitHub
              "raw.githubusercontent.com"
              "api.github.com"
            ];
          };
        in { default = pkgs.mkShell { packages = [ claude-sandboxed ]; }; });
    };
}
