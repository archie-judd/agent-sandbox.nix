# Test fixture: sandbox for deep CWD ancestor traversal
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-deep-cwd";
  allowedPackages = [ pkgs.coreutils pkgs.nodejs ];
}
