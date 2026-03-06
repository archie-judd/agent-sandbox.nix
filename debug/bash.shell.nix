# Debugging shell: drops you into a bash session inside the sandbox.
# Mirror the stateDirs, stateFiles, and allowedPackages from your agent config
# to reproduce the exact environment your agent will see.
#
# Usage:
#   nix-shell debug/bash.shell.nix
#
# Once inside, try:
#   ls $HOME                   # should show only your stateDirs
#   cat $HOME/.claude.json     # should work if in stateFiles
#   ls /tmp                    # should be writable scratch space
#   curl https://example.com   # network should be open
#   which git                  # check allowedPackages are visible
#   ls /some/other/path        # should fail — confirming the sandbox is active
let
  pkgs = import <nixpkgs> { };
  sandbox = import (fetchTarball
    "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz") {
      pkgs = pkgs;
    };
  bash-sandboxed = sandbox.mkSandbox {
    pkg = pkgs.bash;
    binName = "bash";
    outName = "bash-sandboxed";
    allowedPackages =
      [ pkgs.coreutils pkgs.bash pkgs.curl pkgs.git pkgs.which ];
    # Mirror these from your agent config:
    stateDirs = [ "$HOME/.claude" ];
    stateFiles = [ "$HOME/.claude.json" ];
    extraEnv = { };
  };
in pkgs.mkShell { packages = [ bash-sandboxed ]; }
