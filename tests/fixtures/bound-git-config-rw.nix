# Test fixture: a host gitconfig bound into the sandbox via rwDirs (legacy
# mode). The recommended secure path is now roFiles — see
# bound-git-config-ro.nix. This fixture stays so we keep a regression for
# the legacy rwDirs-bound flow.
#
# The test overrides HOME to a throwaway dir and pre-populates
# $HOME/.config/git/config with a [user] block, so the read grant comes from
# this rwDir's OWN bind. git picks it up at its XDG-default global-config path.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
  rwDirs = [ "$HOME/.config/git" ];
}
