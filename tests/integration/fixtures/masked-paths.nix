{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-masked-paths";
  allowedPackages = [ pkgs.coreutils pkgs.git pkgs.python3Minimal ];
  maskedDirs = [ "$PWD/secrets" ];
  maskedFiles = [ "$PWD/.env" "$PWD/a/b/.env" "$PWD/.envrc" "$PWD/missing" ];
}
