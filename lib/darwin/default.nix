/*
  mkDarwinSandbox — wraps a binary using macOS Seatbelt (sandbox-exec).

  This file no longer knows what a seatbelt profile looks like. It validates
  arguments, decides what enters the closure, and produces four things for the
  launcher to read: the spec, the launcher package, the env fragment and the
  stub. Everything about the sandbox itself lives in launcher/, where it can be
  read, type-checked and tested without building anything.

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
  stateDirs ? null,
  stateFiles ? null,
  extraEnv ? null,
}:
let
  # Runs inside the sandbox ahead of the agent binary: probes for a declared
  # git identity and warns the user at launch if none is found, then exec's
  # the real command. See lib/pre-entry-script.sh.
  preEntryScript = pkgs.writeShellScript "pre-entry-script" (
    builtins.readFile ../pre-entry-script.sh
  );

  implicitPackages = [
    pkgs.cacert
    shared.bashWrapper
  ]
  ++ (if allowNix then [ pkgs.nix ] else [ ]);

  pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);

  # cacert and bashWrapper are always included: cacert so SSL/TLS verification
  # works, bashWrapper so the hardcoded SHELL target is always reachable.
  closurePathsFile = pkgs.writeClosure (
    allowedPackages
    ++ implicitPackages
    ++ [
      pkg
      preEntryScript
    ]
  );

  validatedAllowedLocalPorts = shared.validateAllowedLocalPorts allowedLocalPorts;

  sandboxBuildSpec = import ../spec.nix
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
      preEntryScript = preEntryScript;
      allowedDomains = allowedDomains;
      _proxyRedirects = _proxyRedirects;
    };

  # __pycache__ would otherwise change the store hash from one build to the
  # next depending on whether anything had imported the package in place.
  launcherSource = builtins.filterSource (
    path: type: baseNameOf path != "__pycache__"
  ) ../../launcher;

  launcherPackage = pkgs.runCommand "agent-sandbox-launcher" { } ''
    mkdir -p $out
    cp -r ${launcherSource} $out/launcher
  '';

  # One data line per declared variable, and no logic. The values are
  # documented as runtime shell expressions, both the "$TOKEN" form and the
  # sops "$(cat /run/secrets/...)" form, so they expand in the stub and never
  # enter Python or touch disk. toJSON quotes the value, so each line appends
  # exactly one array element even when the value contains spaces.
  envFragment = pkgs.writeText "${outName}-env" (
    pkgs.lib.concatMapStrings (
      name: "DECLARED_ENV+=(${name}=${builtins.toJSON env.${name}})\n"
    ) (builtins.attrNames env)
  );

  stub = pkgs.replaceVars ../stub.sh {
    python = "${pkgs.python3}/bin/python3";
    launcher = "${launcherPackage}";
    spec = "${sandboxBuildSpec}";
    envFragment = "${envFragment}";
  };

in
builtins.seq
  (shared.assertNoLegacyArgs {
    restrictNetwork = restrictNetwork;
    extraEnv = extraEnv;
    stateDirs = stateDirs;
    stateFiles = stateFiles;
  })
  (
    builtins.seq validatedAllowedLocalPorts (
      pkgs.runCommand outName { } ''
        mkdir -p $out/bin
        install -m755 ${stub} $out/bin/${outName}
      ''
      // {
        buildSpec = sandboxBuildSpec;
      }
    )
  )
