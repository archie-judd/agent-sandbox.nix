{ pkgs }:
let
  shared = import ./lib/shared.nix { pkgs = pkgs; };
in
{
  mkSandbox = import ./lib/sandbox.nix {
    pkgs = pkgs;
    shared = shared;
  };
  commonTools = [
    pkgs.coreutils
    pkgs.which
    pkgs.git
    pkgs.ripgrep
    pkgs.fd
    pkgs.gnused
    pkgs.gnugrep
    pkgs.findutils
    pkgs.diffutils
    pkgs.less
    pkgs.gawk
    pkgs.jq
  ];
}
