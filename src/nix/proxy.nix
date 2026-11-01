{ pkgs }:
pkgs.buildGoModule {
  pname = "sandbox-proxy";
  version = pkgs.lib.fileContents ../../version.txt;
  src = ../proxy;
  vendorHash = null;

  __darwinAllowLocalNetworking = true;
}
