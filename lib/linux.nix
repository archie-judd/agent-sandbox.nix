/*
  mkLinuxSandbox — wraps a binary in a bubblewrap (bwrap) container.

  This file no longer knows what a bubblewrap command line looks like. It
  validates arguments and decides what enters the closure; the spec, the
  launcher package, the env fragment and the stub are assembled by
  lib/shared.nix, which both platforms share. Everything about the sandbox
  itself lives in launcher/, where it can be read, type-checked and tested
  without building anything: launcher/launch_config/linux.py holds the binds,
  the mount order and the nftables rules, and launcher/apply_network_rules.py
  applies them inside pasta's namespace.

  Nix keeps eval-time argument validation deliberately: validateAllowedLocalPorts
  and assertNoLegacyArgs throw when the shell is built, not when the agent is
  launched, and moving them into Python would turn a build error into a runtime
  one.

  Nix also keeps writeClosure, and keeps deciding what enters the closure. The
  proxy is referenced only from the spec's proxy block, which is omitted when
  allowedDomains is unset, so an unrestricted wrapper does not carry the Go
  proxy.

  Debugging, for the parts that are still about this platform rather than the
  launcher: "Operation not permitted" on /proc or /dev usually means
  unprivileged user namespaces are disabled on the host, so check that
  kernel.unprivileged_userns_clone is 1. For a missing path, read the computed
  bwrap.args in the session directory the wrapper prints nothing about; it is
  the whole argument list, one NUL-separated entry per line.
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
  # Bound over /proc/cmdline and the boot id, and over git protected files that
  # do not exist yet, which is how a path that could otherwise just be created
  # is made read-only instead.
  emptyFile = pkgs.writeText "sandbox-empty" "";

  hostsFile = pkgs.writeText "sandbox-hosts" ''
    127.0.0.1 localhost
    ::1       localhost
  '';

  implicitPackages = shared.mkImplicitPackages allowNix;

  pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);

  # coreutils is here for the /usr/bin/env symlink, which shebang resolution
  # needs, and deliberately not in implicitPackages, so it does not leak into
  # PATH. macOS resolves that symlink against its own /usr/bin and needs
  # nothing.
  closurePathsFile = pkgs.writeClosure (
    allowedPackages
    ++ implicitPackages
    ++ [
      pkg
      pkgs.coreutils
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
      platform = "linux";
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
      hostsFile = hostsFile;
      emptyFile = emptyFile;
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
