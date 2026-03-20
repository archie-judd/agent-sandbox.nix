# Test: packages outside the closure are not readable/executable inside the sandbox.
#
# We pass the store path of a non-allowed package (hello) into the sandbox via
# extraEnv. The package is built/fetched by Nix (because it's referenced in the
# expression) but is NOT in allowedPackages, so the sandbox should deny access.
let
  pkgs = import <nixpkgs> { };
  sandbox = import ../default.nix { pkgs = pkgs; };
  disallowedPkg = pkgs.hello;
in sandbox.mkSandbox {
  pkg = pkgs.bash;
  binName = "bash";
  outName = "sandboxed-bash-store-isolation";
  allowedPackages = [ pkgs.coreutils pkgs.bash ];
  extraEnv = { DISALLOWED_STORE_PATH = "${disallowedPkg}"; };
}
