{ workspaceDir ? "$PWD", pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-workspace-dir";
  allowedPackages = [ pkgs.coreutils ];
  workspaceDir = workspaceDir;
}
