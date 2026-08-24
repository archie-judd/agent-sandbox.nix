# Test fixture: sandbox with a deeply nested rwDir.
# Exercises ancestor traversal between $HOME and the rwDir target,
# ensuring seatbelt grants file-read-metadata on intermediate directories
# so symlink resolution can reach the allowed path.
#
# STATE_BASE must be set to a temp directory before invoking the sandbox.
# The test script creates it and cleans it up.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-deep-statedir";
  allowedPackages = [ pkgs.coreutils ];
  rwDirs = [ "$HOME/.tmp-test-deep-statedir/a/b/c/data" ];
  rwFiles = [ "$HOME/.tmp-test-deep-statedir/a/b/c/config.json" ];
}
