# Test fixture: sandbox with allowUnixSockets = true and UNIX-socket-capable
# clients (socat, python3) in PATH.
#
# `open` selects the network mode, so the flag is exercised under both
# mechanisms (additive in filtered mode, last-match in open mode).
#
# `nestedRoDir` declares "$PWD/nested-ro" read-only, inside the launch dir,
# for the nested-ro socket denies (issue #84).
#
# `withDeclaredPaths` declares one rwDir, one roDir and one roFile via env
# references ($UNIX_TEST_RW / $UNIX_TEST_RO / $UNIX_TEST_RO_FILE), expanded
# at launch, so a test can point them outside the launch dir. Launches of
# this variant must set all three variables to existing paths.
{ pkgs ? import ../../pinned-nixpkgs.nix { }
, open ? false
, nestedRoDir ? false
, withDeclaredPaths ? false
}:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox ({
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.socat pkgs.python3Minimal ];
  allowUnixSockets = true;
} // (if open then { } else { allowedDomains = [ "anthropic.com" ]; })
  // (if nestedRoDir then { roDirs = [ "$PWD/nested-ro" ]; } else { })
  // (if withDeclaredPaths then {
    rwDirs = [ "$UNIX_TEST_RW" ];
    roDirs = [ "$UNIX_TEST_RO" ];
    roFiles = [ "$UNIX_TEST_RO_FILE" ];
  } else
    { }))
