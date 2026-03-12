# Test fixture: unrestricted network mode
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-unres";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl ];
  restrictNetwork = false;
}
