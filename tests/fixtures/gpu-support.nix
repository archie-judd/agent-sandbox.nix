let
  pkgs = import <nixpkgs> { };
  sandbox = import ../../default.nix { pkgs = pkgs; };
in {
  withGpu = sandbox.mkSandbox {
    pkg = pkgs.bashInteractive;
    binName = "bash";
    outName = "sandboxed-bash-gpu-allowed";
    allowedPackages = [ pkgs.coreutils ];
    allowGpu = true;
  };
  withoutGpu = sandbox.mkSandbox {
    pkg = pkgs.bashInteractive;
    binName = "bash";
    outName = "sandboxed-bash-gpu-denied";
    allowedPackages = [ pkgs.coreutils ];
  };
}
