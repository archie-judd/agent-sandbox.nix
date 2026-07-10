# Test fixture: open-mode sandbox (no allowedDomains) with a UNIX-socket-capable
# client (socat) in PATH. Used to assert that even with the internet open, the
# sandbox cannot reach host loopback services (TCP) or host UNIX sockets. See
# tests/darwin/test-localhost-denied-unrestricted.sh.
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-unres-socat";
  allowedPackages = [ pkgs.coreutils pkgs.curl pkgs.socat pkgs.python3Minimal ];
}
