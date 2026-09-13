# Example: a dev shell with a sandboxed Claude Code binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell shells/claude.shell.nix
let
  pkgs = import <nixpkgs> {
    config.allowUnfreePredicate = pkg: pkgs.lib.getName pkg == "claude-code";
  };
  agent-sandbox =
    import
      (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/refs/tags/v5.2.6.tar.gz") # x-release-please-version
      {
        pkgs = pkgs;
      };
  claude-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    allowedPackages = agent-sandbox.commonTools;
    rwDirs = [ "$HOME/.claude" ];
    # For git identity, uncomment to bind your host gitconfig (see README):
    # roFiles = [ "$HOME/.config/git/config" ];
    env = {
      # Secrets as shell variable references, so they expand at runtime and
      # stay out of the /nix/store.
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      CLAUDE_CONFIG_DIR = "$HOME/.claude";
    };
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
      "raw.githubusercontent.com" = [
        "GET"
        "HEAD"
      ];
      "api.github.com" = [
        "GET"
        "HEAD"
      ];
    };
  };
in
pkgs.mkShell { packages = [ claude-sandboxed ]; }
