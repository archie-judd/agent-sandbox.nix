# Example: a dev shell with a sandboxed Claude Code binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell shells/claude.shell.nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  agent-sandbox =
    import (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")
      {
        pkgs = pkgs;
      };
  claude-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    allowedPackages = agent-sandbox.commonTools;
    rwDirs = [ "$HOME/.claude" ];
    rwFiles = [ ];
    env = {
      # Pass secrets as shell variable references (e.g. "$TOKEN"), not
      # via builtins.getEnv, so they expand at runtime and stay out of
      # the /nix/store.
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      CLAUDE_CONFIG_DIR = "$HOME/.claude";
      # Declare your git identity here (or bind your host gitconfig - see the
      # README):
      # GIT_AUTHOR_NAME = "Your Name";
      # GIT_AUTHOR_EMAIL = "you@example.com";
      # GIT_COMMITTER_NAME = "Your Name";
      # GIT_COMMITTER_EMAIL = "you@example.com";
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
