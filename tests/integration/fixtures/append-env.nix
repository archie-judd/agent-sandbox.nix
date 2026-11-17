# Test fixture: proxy options are appended to values the sandbox already sets.
{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
in
sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-append-env";
  allowedPackages = [
    pkgs.coreutils
    pkgs.bash
  ];
  allowedDomains = [ ];
  env = {
    MAVEN_OPTS = "-Xmx1g";
    MAVEN_ARGS = "-Duser.setting=true";
    JAVA_TOOL_OPTIONS = "-Dfile.encoding=UTF-8";
  };
}
