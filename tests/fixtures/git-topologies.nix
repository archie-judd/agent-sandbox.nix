# Test fixture: a sandbox with git, for the four launch topologies (repository
# root, repository subdirectory, worktree/submodule root, worktree/submodule
# subdirectory).
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-git-topologies";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
}
