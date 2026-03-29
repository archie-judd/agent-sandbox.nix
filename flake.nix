{
  description =
    "Lightweight sandboxing for AI coding agents on Linux (bubblewrap) and macOS (Seatbelt)";

  inputs = { nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; };

  outputs = { self, nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in {
      lib = forAllSystems (system:
        let pkgs = import nixpkgs { system = system; };
        in import ./. { pkgs = pkgs; });
      templates.claude = {
        path = ./templates/claude;
        description =
          "Dev shell with a sandboxed Claude Code binary";
      };
      templates.copilot = {
        path = ./templates/copilot;
        description =
          "Dev shell with a sandboxed GitHub Copilot CLI binary";
      };
      checks = forAllSystems (system:
        let
          mkSandbox = self.lib.${system}.mkSandbox;
          pkgs = import nixpkgs { system = system; };
        in {
          build-trivial-sandbox = mkSandbox {
            pkg = pkgs.coreutils;
            binName = "true";
            outName = "sandboxed-true";
            allowedPackages = [ pkgs.coreutils ];
          };
        });
    };
}
