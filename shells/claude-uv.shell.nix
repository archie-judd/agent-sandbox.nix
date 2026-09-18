# Example: a dev shell with a sandboxed Claude Code binary and uv for Python.
# NixOS users need nix-ld enabled (programs.nix-ld.enable = true).
#
# Usage:
#   export CLAUDE_CODE_OAUTH_TOKEN="your_token_here"
#   nix-shell shells/claude-uv.shell.nix
let
  pkgs = import <nixpkgs> {
    config.allowUnfreePredicate = pkg: pkgs.lib.getName pkg == "claude-code";
  };
  agent-sandbox =
    import
      (fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/refs/tags/v5.2.10.tar.gz") # x-release-please-version
      {
        pkgs = pkgs;
      };

  isLinux = pkgs.stdenv.isLinux;

  # Threaded into LD_LIBRARY_PATH so nix-ld can satisfy dynamic linking for
  # compiled wheels uv installs at runtime.
  dynamicLibraries = [
    pkgs.stdenv.cc.cc
    pkgs.zlib
    pkgs.xorg.libX11
  ];

  # The host LD_LIBRARY_PATH (set by nix-ld) is preserved: dropping it would
  # break glibc resolution for nix-ld itself.
  ldLibraryPath = "${builtins.getEnv "LD_LIBRARY_PATH"}:${pkgs.lib.makeLibraryPath dynamicLibraries}";

  commonPackages = agent-sandbox.commonTools ++ [
    pkgs.uv
    pkgs.python3
  ];

  commonEnv = {
    CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
    CLAUDE_CONFIG_DIR = "$HOME/.claude";
    GITHUB_TOKEN = "$GITHUB_TOKEN";
  };

  # On NixOS, use a nix-managed Python and tell uv not to install its own.
  linuxEnv = {
    UV_NO_MANAGED_PYTHON = "1";
    LD_LIBRARY_PATH = ldLibraryPath;
  };

  claude-sandboxed = agent-sandbox.mkSandbox {
    pkg = pkgs.claude-code;
    binName = "claude";
    outName = "claude-sandboxed";
    rwDirs = [
      "$HOME/.claude"
      "$HOME/.cache/uv"
      "$HOME/.local/share/uv"
    ];
    rwFiles = [ ];
    # For git identity, uncomment to bind your host gitconfig (see README):
    # roFiles = [ "$HOME/.config/git/config" ];
    allowedPackages = commonPackages;
    env = commonEnv // pkgs.lib.optionalAttrs isLinux linuxEnv;
    allowedDomains = {
      "anthropic.com" = "*";
      "claude.com" = "*";
      "githubusercontent.com" = [
        "GET"
        "HEAD"
      ];
      "github.com" = [
        "GET"
        "HEAD"
      ];
      "pypi.org" = [
        "GET"
        "HEAD"
      ];
      "pythonhosted.org" = [
        "GET"
        "HEAD"
      ];
    };

  };

  # uv, python3 and the linuxEnv attrs are repeated below so they also apply
  # in the outer nix-shell, where uv may be invoked directly.
in
pkgs.mkShell {
  packages = [
    pkgs.uv
    pkgs.python3
    claude-sandboxed
  ];
}
// pkgs.lib.optionalAttrs isLinux linuxEnv
