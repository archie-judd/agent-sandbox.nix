{ pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
  nonClosurePkg = pkgs.hello;
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-nix-support";
  allowedPackages = [ pkgs.coreutils ];
  allowNix = true;
  env = {
    NIX_PATH = "nixpkgs=${pkgs.path}";
    NON_CLOSURE_STORE_PATH = "${nonClosurePkg}";
    # In-store nixpkgs path so flake-CLI tests can use `path:$NIXPKGS_SRC#...`
    # instead of an indirect ref like `nixpkgs#...`. The indirect form resolves
    # via the GitHub API and gets rate-limited on shared CI runner IPs.
    NIXPKGS_SRC = "${pkgs.path}";
    # Flake CLI (nix build/run/develop) needs these experimental features. On
    # Linux /etc/nix is not visible inside the sandbox, so the client picks up
    # no global config and must be told here; this is the env.NIX_CONFIG
    # pattern the README documents for nix client config.
    NIX_CONFIG = "experimental-features = nix-command flakes";
  };
}
