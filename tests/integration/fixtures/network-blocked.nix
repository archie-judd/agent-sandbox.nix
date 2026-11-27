# Test fixture: no proxied network, with optional direct TCP grants.
{
  pkgs ? import ../../pinned-nixpkgs.nix { },
  allowedTcpEgress ? [ ],
}:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-block";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl pkgs.python3Minimal ];
  allowedDomains = [ ];
  inherit allowedTcpEgress;
}
