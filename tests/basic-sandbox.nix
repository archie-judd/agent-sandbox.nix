# Test fixture: basic sandbox isolation
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.bash ];
  stateDirs = [ "$HOME/.test-state-dir" ];
  stateFiles = [ "$HOME/.test-state-file" ];
  extraEnv = { TEST_VAR = "test-value"; };
}
