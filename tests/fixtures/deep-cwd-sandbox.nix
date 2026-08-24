# Test fixture: sandbox for deep CWD ancestor traversal
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-deep-cwd";
  allowedPackages = [ pkgs.coreutils pkgs.nodejs ];
}
