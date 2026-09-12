# Test fixture: a roDir and a roFile declared inside the launch directory. The
# test overrides HOME and launches from $HOME/.agent-sandbox-nested-ro, so both
# paths are nested in the read-write launch-directory grant. Neither is nested
# inside another declared path, so the nested-bind refusal does not apply.
{
  pkgs ? import ../../pinned-nixpkgs.nix { },
}:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in
sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-nested-ro-in-cwd";
  allowedPackages = [ pkgs.coreutils ];
  roDirs = [ "$HOME/.agent-sandbox-nested-ro/vendor" ];
  roFiles = [ "$HOME/.agent-sandbox-nested-ro/pinned.txt" ];
}
