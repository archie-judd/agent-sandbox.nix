{ pkgs }:
let
  shared = import ./lib/shared.nix { pkgs = pkgs; };
  mkLinuxSandbox = import ./lib/linux.nix {
    pkgs = pkgs;
    shared = shared;
  };
  mkDarwinSandbox = import ./lib/darwin.nix {
    pkgs = pkgs;
    shared = shared;
  };
in
{
  mkSandbox = if pkgs.stdenv.isDarwin then mkDarwinSandbox else mkLinuxSandbox;
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
