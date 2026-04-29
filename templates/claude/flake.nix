{
  inputs.sandbox.url = "github:archie-judd/agent-sandbox.nix";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, sandbox, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { system = system; };
          claude-sandboxed = sandbox.lib.${system}.mkSandbox {
            pkg = pkgs.claude-code;
            binName = "claude";
            outName = "claude-sandboxed"; # or whatever alias you'd like
            allowedPackages = [
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
            ]; # bash is allowed by default - it is required by the sandbox
            stateDirs = [ "$HOME/.claude" ];
            stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
            extraEnv = {
              # Pass secrets as shell variable references (e.g. "$TOKEN"), not
              # via builtins.getEnv, so they expand at runtime and stay out of
              # the /nix/store.
              CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              GIT_AUTHOR_NAME = "claude";
              GIT_AUTHOR_EMAIL = "claude@localhost";
              GIT_COMMITTER_NAME = "claude";
              GIT_COMMITTER_EMAIL = "claude@localhost";
            };
            restrictNetwork = true;
            allowedDomains = {
              "anthropic.com" = "*";
              "claude.com" = "*";
              "raw.githubusercontent.com" = [ "GET" "HEAD" ];
              "api.github.com" = [ "GET" "HEAD" ];
            };
          };
        in { default = pkgs.mkShell { packages = [ claude-sandboxed ]; }; });
    };
}
