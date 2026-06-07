# Test fixture for the narrowed sysctl-read profile.
# Adds procps (for the `sysctl` CLI) and luajit (for FFI access to the
# integer-MIB form of sysctl(2), used to confirm KERN_PROCARGS2 is blocked).
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.procps pkgs.luajit ];
}
