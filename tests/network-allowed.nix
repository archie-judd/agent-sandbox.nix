# Test fixture: network restricted with allowed domain
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-net";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl ];
  restrictNetwork = true;
  allowedDomains = [ "httpbin.org" ];
}
