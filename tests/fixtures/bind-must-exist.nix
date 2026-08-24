# Test fixture: declared rwDir / rwFile pointing at HOME-relative paths.
# The test overrides HOME to a throwaway dir and controls whether the
# declared paths exist before each launch, so all four cases (both
# missing / only rwDir / only rwFile / all present) can be exercised
# against this single fixture.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-bind-must-exist";
  allowedPackages = [ pkgs.coreutils ];
  rwDirs = [ "$HOME/.agent-sandbox-bind-must-exist/dir" ];
  rwFiles = [ "$HOME/.agent-sandbox-bind-must-exist/file" ];
}
