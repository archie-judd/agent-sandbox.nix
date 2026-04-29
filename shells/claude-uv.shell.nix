# Example: a dev shell with a sandboxed Claude Code binary and uv for Python.
# Handles NixOS dynamic linking so that uv-managed packages (e.g. matplotlib)
# work correctly without uv trying to manage its own Python installation.
#
# NixOS users: make sure nix-ld is enabled in your configuration.nix:
#   programs.nix-ld.enable = true;
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="your_token_here"
#   nix-shell shells/claude-uv.shell.nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  sandbox = import (fetchTarball
    "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz") {
      pkgs = pkgs;
    };

  isLinux = pkgs.stdenv.isLinux;

  # On NixOS, these libraries are threaded into LD_LIBRARY_PATH so that
  # nix-ld can satisfy dynamic link dependencies (libstdc++, zlib, libX11)
  # for any compiled wheels uv installs at runtime.
  dynamicLibraries = [ pkgs.stdenv.cc.cc pkgs.zlib pkgs.xorg.libX11 ];

  # Preserve the host LD_LIBRARY_PATH (set by nix-ld) and prepend our libs.
  # Dropping the host value would break glibc resolution for nix-ld itself.
  ldLibraryPath = "${builtins.getEnv "LD_LIBRARY_PATH"}:${
      pkgs.lib.makeLibraryPath dynamicLibraries
    }";

  commonPackages = [
    pkgs.coreutils
    pkgs.which
    pkgs.git
    pkgs.ripgrep
    pkgs.fd
    pkgs.gnused
    pkgs.gnugrep
    pkgs.findutils
    pkgs.diffutils
    pkgs.less
    pkgs.gawk
    pkgs.jq
    pkgs.uv
    pkgs.python3
  ];

  commonEnv = {
    CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
    GITHUB_TOKEN = "$GITHUB_TOKEN";
    GIT_AUTHOR_NAME = "claude-agent";
    GIT_AUTHOR_EMAIL = "claude-agent@localhost";
    GIT_COMMITTER_NAME = "claude-agent";
    GIT_COMMITTER_EMAIL = "claude-agent@localhost";
  };

  # On NixOS, use a nix-managed Python and tell uv not to install its own.
  # On macOS, uv can manage Python itself without linker workarounds.
  linuxEnv = {
    UV_NO_MANAGED_PYTHON = "1";
    LD_LIBRARY_PATH = ldLibraryPath;
  };

  claude-sandboxed = sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    stateDirs = [ "$HOME/.claude" "$HOME/.cache/uv" "$HOME/.local/share/uv" ];
    stateFiles = [ "$HOME/.claude.json" ];
    allowedPackages = commonPackages;
    extraEnv = commonEnv // pkgs.lib.optionalAttrs isLinux linuxEnv;
    restrictNetwork = true;
    # Broader domain scoping than claude.shell.nix: uv needs access to all
    # github.com / githubusercontent.com subdomains, plus PyPI for packages.
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
      "githubusercontent.com" = [ "GET" "HEAD" ];
      "github.com" = [ "GET" "HEAD" ];
      "pypi.org" = [ "GET" "HEAD" ];
      "pythonhosted.org" = [ "GET" "HEAD" ];
    };

  };

  # uv and python3 are repeated here (also in allowedPackages above) so they are
  # available both inside the sandbox and in the outer nix-shell for ad-hoc use.
  # LD_LIBRARY_PATH / UV_NO_MANAGED_PYTHON are similarly duplicated: extraEnv
  # injects them inside the sandbox, while the attrs below set them in the
  # outer nix-shell where uv may also be invoked directly.
in pkgs.mkShell { packages = [ pkgs.uv pkgs.python3 claude-sandboxed ]; }
// pkgs.lib.optionalAttrs isLinux {
  UV_NO_MANAGED_PYTHON = "1";
  LD_LIBRARY_PATH = ldLibraryPath;
}
