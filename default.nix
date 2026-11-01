{ pkgs }:
{
  mkSandbox = import ./src/nix/sandbox.nix { pkgs = pkgs; };
  commonTools = [
    pkgs.coreutils
    pkgs.curl
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
