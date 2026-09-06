{
  inputs.agent-sandbox.url = "github:archie-judd/agent-sandbox.nix";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, agent-sandbox, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { system = system; };
          sbx = agent-sandbox.lib.${system};
          pi-sandboxed = sbx.mkSandbox {
            pkg = pkgs.pi-coding-agent;
            binName = "pi";
            outName = "pi-sandboxed"; # or whatever alias you'd like
            allowedPackages = sbx.commonTools;
            # Settings, sessions, extensions and skills all live here.
            rwDirs = [ "$HOME/.pi" ];
            rwFiles = [ ];
            # For git identity, uncomment to bind your host gitconfig (see README):
            # roFiles = [ "$HOME/.config/git/config" ];
            env = {
              # Pass secrets as shell variable references (e.g. "$TOKEN"), not
              # via builtins.getEnv, so they expand at runtime and stay out of
              # the /nix/store.
              GEMINI_API_KEY = "$GEMINI_API_KEY";
              ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
              OPENAI_API_KEY = "$OPENAI_API_KEY";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
            };
            # pi defaults to the google provider. Keep the domains of the
            # providers you use, and drop the rest.
            allowedDomains = {
              "generativelanguage.googleapis.com" = "*";
              "anthropic.com" = "*";
              "api.openai.com" = "*";
              # `pi install` fetches extensions from npm.
              "registry.npmjs.org" = [
                "GET"
                "HEAD"
              ];
              "raw.githubusercontent.com" = [
                "GET"
                "HEAD"
              ];
              "api.github.com" = [
                "GET"
                "HEAD"
              ];
            };
          };
        in
        {
          default = pkgs.mkShell { packages = [ pi-sandboxed ]; };
        }
      );
    };
}
