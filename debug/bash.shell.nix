# Debugging shell: drops you into a bash session inside the sandbox.
# Mirror the stateDirs, stateFiles, and allowedPackages from your agent config
# to reproduce the exact environment your agent will see.
#
# Usage:
#   nix-shell debug/bash.shell.nix
#
# Once inside, try:
#   ls $HOME                   # empty ephemeral tmpfs with symlinks to stateDirs/stateFiles
#   cat $HOME/.claude.json     # should work if in stateFiles
#   ls /tmp                    # should be writable scratch space
#   curl https://httpbin.org/get       # allowed domain (GET only) — should work
#   curl -X POST https://httpbin.org/post  # blocked method — should fail
#   curl https://example.com          # blocked domain — should fail
#   which git                  # check allowedPackages are visible
#   ls /some/other/path        # should fail — confirming the sandbox is active
#   cat ~/.ssh/id_ed25519      # should fail — confirming the sandbox is active and your real home isn't visible
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../. { inherit pkgs; };
  bash-sandboxed = sandbox.mkSandbox {
    pkg = pkgs.bashInteractive;
    binName = "bash";
    outName = "bash-sandboxed";
    allowedPackages = [ pkgs.coreutils pkgs.curl pkgs.git pkgs.which ];
    # Mirror these from your agent config:
    stateDirs = [ "$HOME/.claude" ];
    stateFiles = [ "$HOME/.claude.json" ];
    extraEnv = { HELLO = "world"; };
    restrictNetwork = true;
    allowedDomains = { "httpbin.org" = [ "GET" ]; };
  };
in pkgs.mkShell {
  packages = [ bash-sandboxed ];
  shellHook = "bash-sandboxed --norc --noprofile";
}

