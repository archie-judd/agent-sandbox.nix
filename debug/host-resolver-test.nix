# Manual smoke-test wrapper; only dig and shell tools, not a coding agent.
{ pkgs ? import ../tests/pinned-nixpkgs.nix { } }:
let
  sandbox = import ../default.nix { inherit pkgs; };
in
sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandbox-host-dns-test";
  allowedPackages = [ pkgs.bash pkgs.bind.dnsutils pkgs.gnugrep ];
  useHostResolver = true;
}
