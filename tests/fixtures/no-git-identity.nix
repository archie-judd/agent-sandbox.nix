# Test fixture: a sandbox with git but no declared identity — no `env`
# identity and no bound gitconfig. Exercises the fail-closed git-identity
# behaviour and the launch-time warning (the no-identity case).
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
}
