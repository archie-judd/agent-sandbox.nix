{ httpbinPort ? "18918", pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in
sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-credentials";
  allowedPackages = [ pkgs.coreutils pkgs.bash pkgs.curl pkgs.gnugrep ];
  allowedDomains = {
    "httpbin.test" = "*";
  };
  _proxyRedirects = {
    "httpbin.test" = "127.0.0.1:${httpbinPort}";
  };
  injectedCredentials = {
    TEST_TOKEN = {
      secret = "$SANDBOX_TEST_SECRET";
      placeholder = "placeholder-value";
      hosts = {
        "httpbin.test" = { scheme = "bearer"; };
      };
    };
  };
}
