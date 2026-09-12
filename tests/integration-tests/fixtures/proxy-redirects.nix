# Test fixture: the shape check on the _proxyRedirects test hatch.
{
  redirects ? { "httpbin.test" = "127.0.0.1:18918"; },
  pkgs ? import ../../pinned-nixpkgs.nix { },
}:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in
sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-proxy-redirects";
  allowedPackages = [ pkgs.coreutils ];
  allowedDomains = [ "httpbin.test" ];
  _proxyRedirects = redirects;
}
