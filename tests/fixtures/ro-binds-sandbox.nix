# Test fixture: roDir + roFile read-only binds. Tests pre-populate
# $HOME/.test-ro-dir and $HOME/.test-ro-file with known content before
# invoking the sandbox.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-ro-binds";
  allowedPackages = [ pkgs.coreutils ];
  roDirs = [ "$HOME/.test-ro-dir" ];
  roFiles = [ "$HOME/.test-ro-file" ];
}
