# Test fixture: `env` values that reference host variables. The test sets some
# and leaves others unset, which exercises the stub's declare_env gate: every
# value that cannot be resolved is reported against the attribute it came from.
#
# The literal and the spaced value are controls for the quoting the gate has to
# preserve, since it changed how the generated fragment reaches bash.
{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in
sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils ];
  env = {
    ENV_RESOLVED = "$SANDBOX_TEST_RESOLVED";
    ENV_SPACED = "a b  c";
    ENV_MISSING_ONE = "$SANDBOX_TEST_MISSING_ONE";
    ENV_MISSING_TWO = "$SANDBOX_TEST_MISSING_TWO";
  };
}
