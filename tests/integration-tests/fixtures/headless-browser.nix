{
  browser ? "chrome",
  httpbinPort ? null,
  allowHeadlessBrowsers ? null,
  allowUnixSockets ? pkgs.stdenv.hostPlatform.isLinux,
  pkgs ? import ../../pinned-nixpkgs.nix {
    config = {
      allowUnfreePredicate = pkg: (pkg.pname or "") == "google-chrome";
    };
  },
}:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
  browsers = {
    chrome = {
      browser = pkgs.google-chrome;
      binary = pkgs.lib.getExe pkgs.google-chrome;
      driver = pkgs.chromedriver;
      engine = "chromium";
    };
    chromium = {
      browser = pkgs.chromium;
      binary = pkgs.lib.getExe pkgs.chromium;
      driver = pkgs.chromedriver;
      engine = "chromium";
    };
    firefox = {
      browser = pkgs.firefox;
      binary =
        if pkgs.stdenv.hostPlatform.isDarwin then
          "${pkgs.firefox}/Applications/Firefox.app/Contents/MacOS/firefox"
        else
          pkgs.lib.getExe pkgs.firefox;
      driver = pkgs.geckodriver;
      engine = "firefox";
    };
  };
  selected = browsers.${browser};
  ports = [
    18950
    18951
    18952
  ];
  darwinPorts = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin ports;
in
sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-headless-browser";
  allowedPackages = [
    pkgs.coreutils
    pkgs.curl
    pkgs.python3
    selected.browser
    selected.driver
  ];
  env = {
    BROWSER_BINARY = selected.binary;
  };
  allowedDomains = if httpbinPort == null then [ ] else [ "httpbin.test" ];
  _proxyRedirects = if httpbinPort == null then { } else { "httpbin.test" = "127.0.0.1:${httpbinPort}"; };
  allowUnixSockets = allowUnixSockets;
  allowHeadlessBrowsers = if allowHeadlessBrowsers == null then [ selected.engine ] else allowHeadlessBrowsers;
  publishedPorts = darwinPorts;
  allowedHostPorts = darwinPorts;
}
