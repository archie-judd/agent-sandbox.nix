{ publishedPorts ? [ 18944 ], pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-published-ports";
  allowedPackages = [ pkgs.coreutils pkgs.curl pkgs.python3Minimal ];
  # Restricted mode: on darwin the published-port rules are only emitted
  # alongside the restricted network profile (open mode already allows all
  # binds).
  allowedDomains = [ ];
  publishedPorts = publishedPorts;
}
