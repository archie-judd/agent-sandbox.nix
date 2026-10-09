# Test fixture: a workspace pinned away from the launch directory
{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-workspace-pinned";
  allowedPackages = [ pkgs.coreutils pkgs.git pkgs.python3Minimal ];
  workspaceDir = "$HOME/pinned";
}
