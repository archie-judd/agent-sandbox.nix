# mkSandbox. Everything about the sandbox itself lives in launcher/.
{ pkgs }:
let
  errorPrefix = "[ERROR][agent-sandbox.nix]";
  validate = import ./validate.nix {
    pkgs = pkgs;
    errorPrefix = errorPrefix;
  };
  scripts = import ./scripts.nix { pkgs = pkgs; };
  launcherPackage = import ./launcher.nix { pkgs = pkgs; };
  # Forces --norc --noprofile however bash is reached (SHELL, /bin/sh,
  # direct exec), so the sandboxed process cannot source /etc/bashrc or
  # /etc/profile.
  bashWrapper =
    pkgs.runCommand "bash-norc"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
      }
      # bash
      ''
        mkdir -p $out/bin
        makeBinaryWrapper ${pkgs.bashInteractive}/bin/bash $out/bin/bash \
          --add-flags "--norc" \
          --add-flags "--noprofile"
        ln -s bash $out/bin/sh
      '';

  mkImplicitPackages =
    allowNix:
    [
      pkgs.cacert
      bashWrapper
    ]
    ++ (if allowNix then [ pkgs.nix ] else [ ]);

  devOutputs = packages: pkgs.lib.unique (map pkgs.lib.getDev packages);

  mkPkgConfigPathStr =
    packages:
    builtins.concatStringsSep ":" (
      builtins.concatMap (out: [
        "${out}/lib/pkgconfig"
        "${out}/share/pkgconfig"
      ]) (devOutputs packages)
    );

  # One declare_env line per declared variable. toJSON supplies the double
  # quotes the value expands inside, so a value containing spaces stays one
  # word; escapeShellArg carries the fragment through unexpanded until
  # declare_env evals it.
  mkEnvFragment =
    { outName, env }:
    pkgs.writeText "${outName}-env" (
      pkgs.lib.concatMapStrings (
        name:
        "declare_env ${pkgs.lib.escapeShellArg name} ${
          pkgs.lib.escapeShellArg (builtins.toJSON env.${name})
        }\n"
      ) (builtins.attrNames env)
    );

  mkLaunchScript =
    { spec, envFragment }:
    pkgs.replaceVars ../launch.sh {
      bash = "${pkgs.bashInteractive}/bin/bash";
      python = "${pkgs.python3}/bin/python3";
      launcher = "${launcherPackage}";
      spec = "${spec}";
      envFragment = "${envFragment}";
      errorPrefix = errorPrefix;
    };

  # The seqs force the validations at eval time; nothing else does, so
  # without them the errors would only surface when the agent is launched.
  mkWrapper =
    {
      outName,
      launchScript,
      buildSpec,
      legacyArgs,
      allowedHostPorts,
      publishedPorts,
      allowUnixSockets,
      allowHeadlessBrowsers,
      workspaceDir,
      proxyRedirects,
    }:
    builtins.seq (validate.assertNoLegacyArgs legacyArgs) (
      builtins.seq allowedHostPorts (
        builtins.seq publishedPorts (
          builtins.seq allowUnixSockets (
            builtins.seq allowHeadlessBrowsers (
              builtins.seq workspaceDir (
                builtins.seq proxyRedirects (
                  pkgs.runCommand outName { } ''
                    mkdir -p $out/bin
                    install -m755 ${launchScript} $out/bin/${outName}
                  ''
                  // {
                    buildSpec = buildSpec;
                  }
                )
              )
            )
          )
        )
      )
    );
in
{
  pkg,
  binName,
  outName,
  allowedPackages,
  allowNix ? false,
  allowUnixSockets ? false,
  allowHeadlessBrowsers ? [ ],
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

  implicitPackages = mkImplicitPackages allowNix;

  pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);

  pkgConfigPathStr = mkPkgConfigPathStr (allowedPackages ++ implicitPackages);

  closurePathsFile = pkgs.writeClosure (
    allowedPackages
    ++ implicitPackages
    ++ devOutputs (allowedPackages ++ implicitPackages)
    ++ [ pkg ]
    # coreutils supplies the /usr/bin/env symlink target, and is deliberately
    # not in implicitPackages so it does not leak into PATH.
    ++ (if platform == "linux" then [ pkgs.coreutils ] else [ ])
    ++ [ scripts.preEntryScript ]
    ++ (if platform == "darwin" then [ scripts.jobControlScript ] else [ ])
  );

  validatedAllowedHostPorts = validate.validateAllowedHostPorts allowedHostPorts;

  validatedPublishedPorts = validate.validatePublishedPorts publishedPorts;

  validatedAllowHeadlessBrowsers = validate.validateAllowHeadlessBrowsers allowHeadlessBrowsers;

  validatedAllowUnixSockets = validate.validateAllowUnixSockets {
    allowNix = allowNix;
    allowUnixSockets = allowUnixSockets;
    allowHeadlessBrowsers = validatedAllowHeadlessBrowsers;
  };

  validatedWorkspaceDir = validate.validateWorkspaceDir workspaceDir;

  validatedProxyRedirects = validate.validateProxyRedirects _proxyRedirects;

  sandboxBuildSpec =
    import ./spec.nix
      { pkgs = pkgs; }
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
        preEntryScript = scripts.preEntryScript;
        jobControlScript = scripts.jobControlScript;
        bashWrapper = bashWrapper;
        allowedDomains = allowedDomains;
        _proxyRedirects = validatedProxyRedirects;
      };

  envFragment = mkEnvFragment {
    outName = outName;
    env = env;
  };

  launchScript = mkLaunchScript {
    spec = sandboxBuildSpec;
    envFragment = envFragment;
  };

in
mkWrapper {
  outName = outName;
  launchScript = launchScript;
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
