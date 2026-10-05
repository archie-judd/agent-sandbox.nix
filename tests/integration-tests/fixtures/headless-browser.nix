{
  browser ? "chrome",
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
    };
    chromium = {
      browser = pkgs.chromium;
      binary = pkgs.lib.getExe pkgs.chromium;
      driver = pkgs.chromedriver;
    };
    firefox = {
      browser = pkgs.firefox;
      binary =
        if pkgs.stdenv.hostPlatform.isDarwin then
          "${pkgs.firefox}/Applications/Firefox.app/Contents/MacOS/firefox"
        else
          pkgs.lib.getExe pkgs.firefox;
      driver = pkgs.geckodriver;
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
  allowedDomains = [ ];
  allowHeadlessBrowsers = true;
  publishedPorts = darwinPorts;
  allowedHostPorts = darwinPorts;
}
