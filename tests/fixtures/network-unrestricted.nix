# Test fixture: unrestricted network mode
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-unres";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl pkgs.python3Minimal ];
}
