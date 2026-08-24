{ pkgs }:
pkgs.buildGoModule {
  pname = "sandbox-proxy";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
