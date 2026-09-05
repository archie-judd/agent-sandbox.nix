# Example: a dev shell where servers the agent runs are reachable from
# OUTSIDE the sandbox — an integration suite hosting a callback server, or
# a dev server you want to open in the host browser.
# Copy this into your project and adjust as needed.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell shells/claude-published-ports.shell.nix
let
  pkgs = import <nixpkgs> {
    config.allowUnfreePredicate = pkg: pkgs.lib.getName pkg == "claude-code";
  };
  agent-sandbox =
    import (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")
      {
        pkgs = pkgs;
      };
  claude-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    allowedPackages = agent-sandbox.commonTools ++ [ pkgs.nodejs ];
    rwDirs = [ "$HOME/.claude" ];
    env = {
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      CLAUDE_CONFIG_DIR = "$HOME/.claude";
    };
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
    };
    publishedPorts = [
      # host 127.0.0.1:3000 → sandbox :3000 (host processes only). On Linux
      # the sandboxed server must listen on 127.0.0.1 or 0.0.0.0.
      3000
      # The bindAddr is the exposure decision. A docker bridge gateway lets
      # containers call back in via host.docker.internal; 0.0.0.0 would open
      # the port to everything that can reach the host.
      {
        port = 8000;
        bindAddr = "172.17.0.1";
      }
    ];
  };
in
pkgs.mkShell { packages = [ claude-sandboxed ]; }
