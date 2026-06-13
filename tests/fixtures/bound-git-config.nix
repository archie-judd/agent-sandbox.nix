# Test fixture: a host gitconfig bound into the sandbox via rwDirs. The test
# overrides HOME to a throwaway dir and pre-populates
# $HOME/.config/git/config with a [user] block, so the read grant comes from
# this rwDir's OWN seatbelt allow / bind — NOT the deleted GIT_CONFIG_DIR
# machinery. git then picks it up at its XDG-default global-config path.
#
# Follow-up (roDirs / roFiles): once read-only binds ship, add a sibling test
# asserting a gitconfig bound read-only is NOT writable from inside the
# sandbox (the secure, non-host-code-execution identity path).
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
  rwDirs = [ "$HOME/.config/git" ];
}
