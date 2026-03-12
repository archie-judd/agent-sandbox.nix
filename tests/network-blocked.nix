# Test fixture: empty allowlist blocks all network
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-block";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl ];
  restrictNetwork = true;
  allowedDomains = [ ];
}
