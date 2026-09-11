# Test fixture: default sandbox (allowUnixSockets unset) with python3 in
# PATH for AF_UNIX probes. Used to assert that socket(AF_UNIX, ...) is denied
# by the seccomp filter on Linux while socketpair(2) and AF_INET stay
# untouched. See tests/linux/test-unix-socket-default-deny.sh.
{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.python3Minimal ];
}
