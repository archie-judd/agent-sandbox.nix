# Test fixture: stateDir/stateFile access and symlink resolution
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-symlinks";
  allowedPackages = [ pkgs.coreutils ];
  stateDirs = [ "$HOME/.test-state-dir" ];
  stateFiles = [ "$HOME/.test-state-file" ];
  extraEnv = {
    # A nix store path NOT in the closure — for testing that symlink targets
    # outside the closure are bound read-only. (pkgs.hello is not in
    # allowedPackages, so its store path is inaccessible without symlink resolution.)
    NONCLOSURE_STORE_FILE = "${pkgs.hello}/bin/hello";
    # A second non-closure file in the same pkgs.hello store path — shares a
    # common ancestor with NONCLOSURE_STORE_FILE to exercise the sibling-symlink
    # ancestor-dedup regression (Test I).
    NONCLOSURE_STORE_FILE2 = "${pkgs.hello}/share/man/man1/hello.1.gz";
    # A nix store file that IS in the closure (cacert is in implicitPackages).
    # Used to test that _is_already_bound correctly deduplicates.
    CLOSURE_STORE_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };
}
