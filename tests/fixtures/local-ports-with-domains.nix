# Test fixture: allowedDomains and allowedLocalPorts together. This is the
# combination where a client honouring HTTP_PROXY would hand the proxy a
# loopback request, which the proxy refuses, rather than taking the direct
# path allowedLocalPorts opened.
{ ports ? [ 18939 ], httpbinPort ? "18918", pkgs ? import ../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-local-ports-domains";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl pkgs.gnugrep ];
  allowedDomains = [ "httpbin.test" ];
  allowedLocalPorts = ports;
  _proxyRedirects = { "httpbin.test" = "127.0.0.1:${httpbinPort}"; };
}
