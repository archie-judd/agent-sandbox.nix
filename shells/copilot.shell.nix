# Example: a dev shell with a sandboxed Copilot binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export GITHUB_TOKEN="your_token_here"
#   nix-shell shells/copilot.shell.nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  sandbox = import (fetchTarball
    "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz") {
      pkgs = pkgs;
    };
  copilot-sandboxed = sandbox.mkSandbox {
    pkg = pkgs.github-copilot-cli;
    binName = "copilot";
    outName = "copilot-sandboxed";
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
    ];
    stateDirs = [ "$HOME/.config/github-copilot" "$HOME/.copilot" ];
    stateFiles = [ ];
    extraEnv = {
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      GIT_AUTHOR_NAME = "copilot";
      GIT_AUTHOR_EMAIL = "copilot@localhost";
      GIT_COMMITTER_NAME = "copilot";
      GIT_COMMITTER_EMAIL = "copilot@localhost";
    };
    restrictNetwork = true;
    allowedDomains = [
      # GitHub Copilot
      "githubcopilot.com"
      # GitHub
      "githubusercontent.com"
      "github.com"
    ];

  };

in pkgs.mkShell { packages = [ copilot-sandboxed ]; }
