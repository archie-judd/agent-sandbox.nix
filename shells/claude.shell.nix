# Example: a dev shell with a sandboxed Claude Code binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell shells/claude.shell.nix
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
      pkgs.diffutils
      pkgs.less
      pkgs.gawk
      pkgs.jq
    ];
    stateDirs = [ "$HOME/.claude" ];
    stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
    extraEnv = {
      # Pass secrets as shell variable references (e.g. "$TOKEN"), not
      # via builtins.getEnv, so they expand at runtime and stay out of
      # the /nix/store.
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      GIT_AUTHOR_NAME = "claude";
      GIT_AUTHOR_EMAIL = "claude@localhost";
      GIT_COMMITTER_NAME = "claude";
      GIT_COMMITTER_EMAIL = "claude@localhost";
    };
    restrictNetwork = true;
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
      "raw.githubusercontent.com" = [ "GET" "HEAD" ];
      "api.github.com" = [ "GET" "HEAD" ];
    };
  };
in pkgs.mkShell { packages = [ claude-sandboxed ]; }
