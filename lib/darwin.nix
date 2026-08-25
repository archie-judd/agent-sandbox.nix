/*
  mkDarwinSandbox — wraps a binary using macOS Seatbelt (sandbox-exec).

  This file no longer knows what a seatbelt profile looks like. It validates
  arguments and decides what enters the closure; the spec, the launcher
  package, the env fragment and the stub are assembled by lib/shared.nix,
  which both platforms share. Everything about the sandbox itself lives in
  launcher/, where it can be read, type-checked and tested without building
  anything.

  Nix keeps eval-time argument validation deliberately: validateAllowedLocalPorts
  and assertNoLegacyArgs throw when the shell is built, not when the agent is
  launched, and moving them into Python would turn a build error into a runtime
  one.

  Nix also keeps writeClosure, and keeps deciding what enters the closure. The
  proxy is referenced only from the spec's proxy block, which is omitted when
  allowedDomains is unset, so an unrestricted wrapper does not carry the Go
  proxy.
*/
{ pkgs, shared }:
{
  pkg,
  binName,
  outName,
  allowedPackages,
  allowNix ? false,
  rwDirs ? [ ],
  rwFiles ? [ ],
  roDirs ? [ ],
  roFiles ? [ ],
  env ? { },
  allowedDomains ? null,
  allowedLocalPorts ? [ ],
  # Internal: maps "host" → "addr:port" so the proxy dials the local address
  # for those hosts instead of resolving the original. Used by the test
  # harness to point fake domains at a local httpbin. Not part of the
  # public API — leading underscore signals internal-only.
  _proxyRedirects ? { },
  # Legacy args that should not be used in new code. Still accepted for
  # backward compatibility, but will throw an error if used with
  # assertNoLegacyArgs.
  restrictNetwork ? null,
  extraEnv ? null,
  stateDirs ? null,
  stateFiles ? null,
}:
let
  implicitPackages = shared.mkImplicitPackages allowNix;

  pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);

  closurePathsFile = pkgs.writeClosure (
    allowedPackages
    ++ implicitPackages
    ++ [
      pkg
      shared.preEntryScript
    ]
  );

  validatedAllowedLocalPorts = shared.validateAllowedLocalPorts allowedLocalPorts;

  sandboxBuildSpec = import ./spec.nix
    {
      pkgs = pkgs;
      shared = shared;
    }
    {
      platform = "darwin";
      outName = outName;
      pkg = pkg;
      binName = binName;
      sandboxPath = pathStr;
      allowNix = allowNix;
      rwDirs = rwDirs;
      rwFiles = rwFiles;
      roDirs = roDirs;
      roFiles = roFiles;
      env = env;
      allowedLocalPorts = validatedAllowedLocalPorts;
      closurePathsFile = closurePathsFile;
      preEntryScript = shared.preEntryScript;
      allowedDomains = allowedDomains;
      _proxyRedirects = _proxyRedirects;
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
  };
  allowedLocalPorts = validatedAllowedLocalPorts;
}
