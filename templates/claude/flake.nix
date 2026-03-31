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
              pkgs.jq
            ]; # bash is allowed by default - it is required by the sandbox
            stateDirs = [ "$HOME/.claude" ];
            stateFiles = [ "$HOME/.claude.json" "$HOME/.claude.json.lock" ];
            extraEnv = {
              # Use literal strings for secrets to evaluate at runtime!
              # builtins.getEnv will leak your token into the /nix/store.
              CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              GIT_AUTHOR_NAME = "claude";
              GIT_AUTHOR_EMAIL = "claude@localhost";
              GIT_COMMITTER_NAME = "claude";
              GIT_COMMITTER_EMAIL = "claude@localhost";
            };
            restrictNetwork = true;
            allowedDomains = {
              # Anthropic
              "anthropic.com" = "*";
              "claude.com" = "*";
              # GitHub
              "raw.githubusercontent.com" = [ "GET" "HEAD" ];
              "api.github.com" = [ "GET" "HEAD" ];
            };
          };
        in {
          default = pkgs.mkShell {
            packages = [ claude-sandboxed ];
          };
        });
    };
}
