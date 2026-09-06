# Example: a dev shell with a sandboxed opencode that talks to Ollama running
# on the host. The agent has no internet access at all: allowedDomains = [ ]
# blocks every domain, and allowedHostPorts opens only the Ollama port.
#
# Ollama runs on the host, not in the sandbox, so it keeps its GPU access.
#
# Usage:
#   ollama serve   # on the host, in another terminal
#   nix-shell shells/opencode-ollama.shell.nix
#
# Point opencode at Ollama in $HOME/.config/opencode/opencode.json on the host,
# with an openai-compatible provider whose baseURL is the address below. That
# directory is a rwDir, so the sandbox reads the same config.
let
  pkgs = import <nixpkgs> { };
  agent-sandbox =
    import (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")
      {
        pkgs = pkgs;
      };
  ollamaPort = 11434;
  opencode-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.opencode;
    binName = "opencode";
    outName = "opencode-sandboxed";
    allowedPackages = agent-sandbox.commonTools;
    rwDirs = [
      "$HOME/.config/opencode"
      "$HOME/.local/share/opencode"
      "$HOME/.local/state/opencode"
      "$HOME/.cache/opencode"
    ];
    # For git identity, uncomment to bind your host gitconfig (see README):
    # roFiles = [ "$HOME/.config/git/config" ];
    env = {
      OLLAMA_HOST = "http://localhost:${toString ollamaPort}";
    };
    # No internet. opencode still refreshes its model catalogue from models.dev
    # at startup, so if it will not start, allow that one domain:
    #   allowedDomains = { "models.dev" = [ "GET" "HEAD" ]; };
    allowedDomains = [ ];
    allowedHostPorts = [ ollamaPort ];
  };
in
pkgs.mkShell { packages = [ opencode-sandboxed ]; }
