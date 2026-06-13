# Test fixture: a sandbox with git but no declared identity — no `env`
# identity and no bound gitconfig. Exercises the fail-closed git-identity
# behaviour and the launch-time warning (the no-identity case).
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
}
