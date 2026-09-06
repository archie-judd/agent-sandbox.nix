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
          # Codex sandboxes itself too, and the two cannot nest: without
          # `-s danger-full-access` every command fails with "Failed to create
          # unified exec process: Operation not permitted". Run it with that
          # flag and let this sandbox do the work. See "Agent notes" in the
          # README.
          codex-sandboxed = sbx.mkSandbox {
            pkg = pkgs.codex;
            binName = "codex";
            outName = "codex-sandboxed"; # or whatever alias you'd like
            allowedPackages = sbx.commonTools;
            rwDirs = [ "$HOME/.codex" ];
            rwFiles = [ ];
            # For git identity, uncomment to bind your host gitconfig (see README):
            # roFiles = [ "$HOME/.config/git/config" ];
            env = {
              # Pass secrets as shell variable references (e.g. "$TOKEN"), not
              # via builtins.getEnv, so they expand at runtime and stay out of
              # the /nix/store.
              OPENAI_API_KEY = "$OPENAI_API_KEY";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              CODEX_HOME = "$HOME/.codex";
            };
            allowedDomains = {
              "api.openai.com" = "*";
              "chatgpt.com" = "*";
              "github.com/openai" = "*";
              "files.openai.com" = [
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
              "github.com" = [
                "GET"
                "HEAD"
              ];
              "codeload.github.com" = [
                "GET"
                "HEAD"
              ];
            };
          };
        in
        {
          default = pkgs.mkShell { packages = [ codex-sandboxed ]; };
        }
      );
    };
}
