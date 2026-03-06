# Example: a dev shell with a sandboxed Copilot binary.
# Copy this into your project and adjust as needed.
#
# Usage:
#   nix-shell examples/copilot.shell.nix

let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  sandbox = import ./. { pkgs = pkgs; };
  copilot-sandboxed = sandbox.mkSandbox {
    pkg = pkgs.github-copilot-cli;
    binName = "copilot";
    outName = "copilot-sandboxed";
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
    stateDirs = [ "$HOME/.config/github-copilot" "$HOME/.copilot" ];
    stateFiles = [ ];
    extraEnv = {
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      GIT_AUTHOR_NAME = "copilot-agent";
      GIT_AUTHOR_EMAIL = "copilot-agent@localhost";
      GIT_COMMITTER_NAME = "copilot-agent";
      GIT_COMMITTER_EMAIL = "copilot-agent@localhost";
    };
  };

in pkgs.mkShell { packages = [ copilot-sandboxed ]; }
