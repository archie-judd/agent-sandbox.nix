{ ports ? [ 18934 ] }:
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-allowed-local-ports";
  allowedPackages = [ pkgs.coreutils pkgs.curl pkgs.python3Minimal ];
  allowedLocalPorts = ports;
}
