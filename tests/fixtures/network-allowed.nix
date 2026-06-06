# Test fixture: network restricted with allowed domain.
# httpbin.test is redirected to a local go-httpbin started by the test
# harness, so tests don't depend on public services. The port is passed
# in via --argstr httpbinPort.
{ httpbinPort ? "18918" }:
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-net";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl ];
  restrictNetwork = true;
  allowedDomains = [ "httpbin.test" ];
  _proxyRedirects = { "httpbin.test" = "127.0.0.1:${httpbinPort}"; };
}
