# Test fixture: bash-interactive warning (darwin only)
# This should trigger a warning when run on darwin
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;  # bash is an alias for bash-interactive
  binName = "bash";
  outName = "sandboxed-bash-interactive";
  allowedPackages = [ pkgs.coreutils pkgs.bash ];
  stateDirs = [ ];
  stateFiles = [ ];
  extraEnv = { };
}
