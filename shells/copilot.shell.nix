# Example: a dev shell with a sandboxed Copilot binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export GITHUB_TOKEN="your_token_here"
#   nix-shell shells/copilot.shell.nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  agent-sandbox =
    import (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")
      {
        pkgs = pkgs;
      };
  copilot-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.github-copilot-cli;
    binName = "copilot";
    outName = "copilot-sandboxed";
    allowedPackages = agent-sandbox.commonTools;
    rwDirs = [
      "$HOME/.config/github-copilot"
      "$HOME/.copilot"
    ];
    rwFiles = [ ];
    env = {
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      # Declare your git identity here (or bind your host gitconfig - see the
      # README):
      # GIT_AUTHOR_NAME = "Your Name";
      # GIT_AUTHOR_EMAIL = "you@example.com";
      # GIT_COMMITTER_NAME = "Your Name";
      # GIT_COMMITTER_EMAIL = "you@example.com";
    };
    allowedDomains = {
      "githubcopilot.com" = "*";
      "github.com" = "*";
      "githubusercontent.com" = [
        "GET"
        "HEAD"
      ];
    };

  };

in
pkgs.mkShell { packages = [ copilot-sandboxed ]; }
