# Test fixture: basic sandbox isolation
{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.python3Minimal ];
  rwDirs = [ "$HOME/.test-state-dir" ];
  rwFiles = [ "$HOME/.test-state-file" ];
  env = { TEST_VAR = "test-value"; };
}
