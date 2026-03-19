# Example: a dev shell with a sandboxed Claude Code binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell examples/claude.shell.nix
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
in pkgs.mkShell { packages = [ claude-sandboxed ]; }
