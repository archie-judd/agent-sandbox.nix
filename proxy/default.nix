{ pkgs }:
pkgs.buildGoModule {
  pname = "sandbox-proxy";
  version = pkgs.lib.fileContents ../version.txt;
  src = ./.;
  vendorHash = null;
}
