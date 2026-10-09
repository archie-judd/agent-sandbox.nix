# Test fixture: pkg-config wiring for allowedPackages
{ pkgs ? import ../../pinned-nixpkgs.nix { } }:
let
  sandbox = import ../../../default.nix { pkgs = pkgs; };
  shareOnlyLib = pkgs.runCommand "sandbox-share-only-pc" { } ''
    mkdir -p "$out/share/pkgconfig"
    cat > "$out/share/pkgconfig/sandbox-share-only.pc" <<'EOF'
    Name: sandbox-share-only
    Description: fixture whose pkgconfig data lives in share/pkgconfig
    Version: 1.0
    EOF
  '';
in sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "sandboxed-bash-pkg-config";
  allowedPackages = [
    pkgs.coreutils
    pkgs.pkg-config
    pkgs.libffi
    pkgs.zlib
    shareOnlyLib
  ];
}
