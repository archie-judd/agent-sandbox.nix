# Test fixture: a git identity declared via `env`
# (GIT_AUTHOR_* / GIT_COMMITTER_*). git in allowedPackages so the launch-time
# probe runs and resolves the declared identity (the no-warning case).
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash";
  allowedPackages = [ pkgs.coreutils pkgs.git ];
  env = {
    GIT_AUTHOR_NAME = "Sandbox Tester";
    GIT_AUTHOR_EMAIL = "sandbox-tester@example.com";
    GIT_COMMITTER_NAME = "Sandbox Tester";
    GIT_COMMITTER_EMAIL = "sandbox-tester@example.com";
  };
}
