# Test fixture: a roFile declared underneath an rwDir ancestor. Both paths are
# HOME-relative and the test overrides HOME, so the nesting is entirely under
# the test's control. This is the shape the README recommends for git identity
# (roFiles = [ "$HOME/.config/git/config" ]) landing under a declared parent.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-nested-binds";
  allowedPackages = [ pkgs.coreutils ];
  rwDirs = [ "$HOME/.agent-sandbox-nested-binds" ];
  roFiles = [ "$HOME/.agent-sandbox-nested-binds/git/config" ];
}
