{
  inputs.agent-sandbox.url = "github:archie-judd/agent-sandbox.nix";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, agent-sandbox, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            system = system;
            config = {
              allowUnfreePredicate = pkg: pkgs.lib.getName pkg == "antigravity-cli";
            };
          };
          sbx = agent-sandbox.lib.${system};
          agy-sandboxed = sbx.mkSandbox {
            pkg = pkgs.antigravity-cli;
            binName = "agy";
            outName = "agy-sandboxed"; # or whatever alias you'd like
            allowedPackages = sbx.commonTools;
            # Uncomment to always work in one directory, wherever you launch from:
            # workspaceDir = "$HOME/projects/my-project";
            rwDirs = [
              "$HOME/.antigravity"
              "$HOME/.gemini"
            ];
            rwFiles = [ ];
            # For git identity, uncomment to bind your host gitconfig (see README):
            # roFiles = [ "$HOME/.config/git/config" ];
            env = {
              # Pass secrets as shell variable references (e.g. "$TOKEN"), not
              # via builtins.getEnv, so they expand at runtime and stay out of
              # the /nix/store.
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              GEMINI_API_KEY = "$GEMINI_API_KEY";
            };
            allowedDomains = {
              "antigravity.google" = "*";
              "googleapis.com" = "*";
              "accounts.google.com" = "*";
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
          default = pkgs.mkShell {
            packages = [
              agy-sandboxed
            ];
          };
        }
      );
    };
}
