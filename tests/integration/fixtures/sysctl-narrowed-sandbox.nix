# Test fixture for the narrowed sysctl-read profile.
# Adds luajit, for FFI access to the integer-MIB form of sysctl(2).
{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.luajit ];
}
