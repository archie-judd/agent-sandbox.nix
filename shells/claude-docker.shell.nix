# Example: a dev shell where a docker container on the host drives a dev
# server the agent runs inside the sandbox. Claude runs the app, a Playwright
# container runs the browser tests against it.
#
# Docker runs on the host, not in the sandbox, so the sandbox never needs the
# docker socket. Only the dev server port crosses the boundary.
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"
#   nix-shell shells/claude-docker.shell.nix
#
#   # in the sandbox
#   npm run dev
#
#   # on the host, in another terminal
#   docker run --rm mcr.microsoft.com/playwright \
#     npx playwright test --base-url http://host.docker.internal:3000
let
  pkgs = import <nixpkgs> {
    config.allowUnfreePredicate = pkg: pkgs.lib.getName pkg == "claude-code";
  };
  agent-sandbox =
    import (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")
      {
        pkgs = pkgs;
      };
  devServerPort = 3000;
  claude-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    allowedPackages = agent-sandbox.commonTools ++ [ pkgs.nodejs ];
    rwDirs = [ "$HOME/.claude" ];
    # For git identity, uncomment to bind your host gitconfig (see README):
    # roFiles = [ "$HOME/.config/git/config" ];
    env = {
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      CLAUDE_CONFIG_DIR = "$HOME/.claude";
    };
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
    };
    publishedPorts = [
      # 172.17.0.1 is the default docker bridge gateway on Linux, so containers
      # reach the dev server as host.docker.internal without the port being
      # open to anything else. Confirm yours with `docker network inspect
      # bridge`. Docker Desktop on macOS has no such host interface and needs a
      # wider bindAddr, which exposes the port more broadly.
      #
      # On Linux the sandboxed dev server must listen on 127.0.0.1 or 0.0.0.0.
      {
        port = devServerPort;
        bindAddr = "172.17.0.1";
      }
    ];
  };
in
pkgs.mkShell { packages = [ claude-sandboxed ]; }
