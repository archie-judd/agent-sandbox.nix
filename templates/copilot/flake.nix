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
          copilot-sandboxed = sbx.mkSandbox {
            pkg = pkgs.github-copilot-cli;
            binName = "copilot";
            outName = "copilot-sandboxed"; # or whatever alias you'd like
            allowedPackages = sbx.commonTools;
            rwDirs = [
              "$HOME/.config/github-copilot"
              "$HOME/.copilot"
            ];
            rwFiles = [ ];
            env = {
              # Pass secrets as shell variable references (e.g. "$TOKEN"), not
              # via builtins.getEnv, so they expand at runtime and stay out of
              # the /nix/store.
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              # Declare your git identity here (or bind your host gitconfig -
              # see the README):
              # GIT_AUTHOR_NAME = "Your Name";
              # GIT_AUTHOR_EMAIL = "you@example.com";
              # GIT_COMMITTER_NAME = "Your Name";
              # GIT_COMMITTER_EMAIL = "you@example.com";
            };
            allowedDomains = {
              "githubcopilot.com" = "*";
              "github.com" = "*";
              "githubusercontent.com" = [
                "GET"
                "HEAD"
              ];
            };
          };
        in
        {
          default = pkgs.mkShell { packages = [ copilot-sandboxed ]; };
        }
      );
    };
}
