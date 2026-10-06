# Example: a dev shell where Claude runs browser tests against a headless
# Chromium-engine browser inside the sandbox. Google Chrome on macOS, where
# nixpkgs has no Chromium; Chromium on Linux.
#
# The browser is driven by chromedriver over WebDriver. Your test suite's
# driver config needs the settings in the README's "Using headless browsers
# inside the sandbox" section.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell shells/claude-chromium.shell.nix
let
  pkgs = import <nixpkgs> {
    config.allowUnfreePredicate =
      pkg:
      builtins.elem (pkgs.lib.getName pkg) [
        "claude-code"
        "google-chrome"
      ];
  };
  agent-sandbox =
    import
      (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/refs/tags/v5.5.0.tar.gz") # x-release-please-version
      {
        pkgs = pkgs;
      };
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  browser = if isDarwin then pkgs.google-chrome else pkgs.chromium;
  chromedriverPort = 9515;
  appServerPort = 3000;
  claude-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    allowedPackages = agent-sandbox.commonTools ++ [
      browser
      pkgs.chromedriver
    ];
    rwDirs = [ "$HOME/.claude" ];
    env = {
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      CLAUDE_CONFIG_DIR = "$HOME/.claude";
      CHROME_BIN = pkgs.lib.getExe browser;
    };
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
    };
    allowHeadlessBrowsers = [ "chromium" ];
    # Linux only: the profile lock needs AF_UNIX, which seccomp cannot scope.
    allowUnixSockets = !isDarwin;
    # macOS restricted mode only: localhost is shared with the host, so the
    # driver and the app under test listen on declared ports.
    publishedPorts = pkgs.lib.optionals isDarwin [
      chromedriverPort
      appServerPort
    ];
    allowedHostPorts = pkgs.lib.optionals isDarwin [
      chromedriverPort
      appServerPort
    ];
  };
in
pkgs.mkShell { packages = [ claude-sandboxed ]; }
