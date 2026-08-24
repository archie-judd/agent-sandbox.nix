# Test fixture: a host gitconfig bound into the sandbox read-only via
# roFiles. This is the recommended secure path for git identity — the
# agent reads [user] through git's normal global-config lookup, but
# cannot write core.hooksPath / core.fsmonitor / aliases that would
# fire host code on the next host `git` invocation.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
  roFiles = [ "$HOME/.config/git/config" ];
}
