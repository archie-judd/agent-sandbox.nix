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
          opencode-sandboxed = sbx.mkSandbox {
            pkg = pkgs.opencode;
            binName = "opencode";
            outName = "opencode-sandboxed"; # or whatever alias you'd like
            allowedPackages = sbx.commonTools;
            rwDirs = [
              "$HOME/.config/opencode"
              "$HOME/.local/share/opencode"
              "$HOME/.local/state/opencode"
              "$HOME/.cache/opencode"
            ];
            rwFiles = [ ];
            # For git identity, uncomment to bind your host gitconfig (see README):
            # roFiles = [ "$HOME/.config/git/config" ];
            env = {
              # Pass secrets as shell variable references (e.g. "$TOKEN"), not
              # via builtins.getEnv, so they expand at runtime and stay out of
              # the /nix/store.
              ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
              OPENAI_API_KEY = "$OPENAI_API_KEY";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
            };
            # opencode is multi-provider: keep the domains of the providers you
            # configure, and drop the rest.
            allowedDomains = {
              "opencode.ai" = "*";
              "models.dev" = [
                "GET"
                "HEAD"
              ];
              "anthropic.com" = "*";
              "api.openai.com" = "*";
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
          default = pkgs.mkShell { packages = [ opencode-sandboxed ]; };
        }
      );
    };
}
