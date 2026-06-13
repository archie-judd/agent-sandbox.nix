# Test fixture: filtered-network sandbox (allowedDomains set) with a
# UNIX-socket-capable client (socat) in PATH. Used to assert that connect()
# to a UNIX-domain socket on the host is denied. See
# tests/darwin/test-unix-socket-egress-denied.sh.
#
# Open and filtered modes both deny AF_UNIX outbound, by different
# mechanisms: filtered mode never grants (allow network*), so AF_UNIX falls
# under deny-default; open mode grants (allow network*) but layers a
# (deny network-outbound (remote unix-socket)) on top (with a path-literal
# allow for /private/var/run/mDNSResponder so DNS still works). This
# fixture exercises the filtered-mode mechanism; the open-mode mechanism
# is covered by tests/darwin/test-localhost-denied-unrestricted.sh.
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.socat ];
  allowedDomains = [ "anthropic.com" ];
}
