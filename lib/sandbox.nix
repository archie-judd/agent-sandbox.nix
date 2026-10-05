# mkSandbox. Everything about the sandbox itself lives in launcher/.
{ pkgs, shared }:
{
  pkg,
  binName,
  outName,
  allowedPackages,
  allowNix ? false,
  allowUnixSockets ? false,
  allowHeadlessBrowsers ? false,
  rwDirs ? [ ],
  rwFiles ? [ ],
  roDirs ? [ ],
  roFiles ? [ ],
  env ? { },
  workspaceDir ? "$PWD",
  allowedDomains ? null,
  allowedHostPorts ? [ ],
  publishedPorts ? [ ],
  # Internal, for the test harness: maps "host" to "addr:port" so the proxy
  # dials a local address instead of resolving the original.
  _proxyRedirects ? { },
  # Legacy args: accepted so assertNoLegacyArgs can name them in its error.
  restrictNetwork ? null,
  extraEnv ? null,
  stateDirs ? null,
  stateFiles ? null,
  allowedLocalPorts ? null,
}:
let
  platform = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux";

  implicitPackages = shared.mkImplicitPackages allowNix;

  pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);

  pkgConfigPathStr = shared.mkPkgConfigPathStr (allowedPackages ++ implicitPackages);

  closurePathsFile = pkgs.writeClosure (
    allowedPackages
    ++ implicitPackages
    ++ shared.devOutputs (allowedPackages ++ implicitPackages)
    ++ [ pkg ]
    # coreutils supplies the /usr/bin/env symlink target, and is deliberately
    # not in implicitPackages so it does not leak into PATH.
    ++ (if platform == "linux" then [ pkgs.coreutils ] else [ ])
    ++ [ shared.preEntryScript ]
  );

  validatedAllowedHostPorts = shared.validateAllowedHostPorts allowedHostPorts;

  validatedPublishedPorts = shared.validatePublishedPorts publishedPorts;

  validatedAllowUnixSockets = shared.validateAllowUnixSockets {
    allowNix = allowNix;
    allowUnixSockets = allowUnixSockets;
  };

  validatedAllowHeadlessBrowsers = shared.validateAllowHeadlessBrowsers allowHeadlessBrowsers;

  validatedWorkspaceDir = shared.validateWorkspaceDir workspaceDir;

  validatedProxyRedirects = shared.validateProxyRedirects _proxyRedirects;

  sandboxBuildSpec =
    import ./spec.nix
      {
        pkgs = pkgs;
        shared = shared;
      }
      {
        platform = platform;
        outName = outName;
        pkg = pkg;
        binName = binName;
        sandboxPath = pathStr;
        pkgConfigPath = pkgConfigPathStr;
        allowNix = allowNix;
        rwDirs = rwDirs;
        rwFiles = rwFiles;
        roDirs = roDirs;
        roFiles = roFiles;
        env = env;
        workspaceDir = validatedWorkspaceDir;
        allowedHostPorts = validatedAllowedHostPorts;
        publishedPorts = validatedPublishedPorts;
        allowUnixSockets = validatedAllowUnixSockets;
        allowHeadlessBrowsers = validatedAllowHeadlessBrowsers;
        closurePathsFile = closurePathsFile;
        preEntryScript = shared.preEntryScript;
        allowedDomains = allowedDomains;
        _proxyRedirects = validatedProxyRedirects;
      };

  envFragment = shared.mkEnvFragment {
    outName = outName;
    env = env;
  };

  stub = shared.mkStub {
    spec = sandboxBuildSpec;
    envFragment = envFragment;
  };

in
shared.mkWrapper {
  outName = outName;
  stub = stub;
  buildSpec = sandboxBuildSpec;
  legacyArgs = {
    restrictNetwork = restrictNetwork;
    extraEnv = extraEnv;
    stateDirs = stateDirs;
    stateFiles = stateFiles;
    allowedLocalPorts = allowedLocalPorts;
  };
  allowedHostPorts = validatedAllowedHostPorts;
  publishedPorts = validatedPublishedPorts;
  allowUnixSockets = validatedAllowUnixSockets;
  allowHeadlessBrowsers = validatedAllowHeadlessBrowsers;
  workspaceDir = validatedWorkspaceDir;
  proxyRedirects = validatedProxyRedirects;
}
