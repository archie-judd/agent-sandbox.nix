{ pkgs }:
let
  errorPrefix = "[ERROR][agent-sandbox.nix]";
  sandboxProxy = import ../proxy { pkgs = pkgs; };
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
  # The proxy's JSON config: { "domain": "*" | ["GET","HEAD"], ... }. A
  # plain list means every domain gets "*".
  mkAllowlistFile =
    allowedDomains:
    let
      attrset =
        if builtins.isList allowedDomains then
          builtins.listToAttrs (
            map (d: {
              name = d;
              value = "*";
            }) allowedDomains
          )
        else
          allowedDomains;
    in
    pkgs.writeText "sandbox-allowlist.json" (builtins.toJSON attrset);
  # Shared by the host-port and published-port validators.
  validPort = port: builtins.isInt port && port >= 1 && port <= 65535;
  validateAllowedHostPorts =
    allowedHostPorts:
    if allowedHostPorts == null then
      null
    else if !(builtins.isList allowedHostPorts) then
      builtins.throw "${errorPrefix} allowedHostPorts must be null or a list of integers from 1 to 65535"
    else
      let
        invalidPorts = builtins.filter (port: !validPort port) allowedHostPorts;
      in
      if invalidPorts != [ ] then
        builtins.throw "${errorPrefix} allowedHostPorts must only contain integers from 1 to 65535 (null allows all). Invalid: ${builtins.toJSON invalidPorts}"
      else
        pkgs.lib.unique allowedHostPorts;
  # Deliberately no null form: "every port, reachable from the host" is
  # never the intended published surface, unlike allowedHostPorts' null.
  validatePublishedPorts =
    publishedPorts:
    if !(builtins.isList publishedPorts) then
      builtins.throw "${errorPrefix} publishedPorts must be a list whose entries are integers from 1 to 65535 or { port = <int>; bindAddr = \"<ipv4>\"; }"
    else
      let
        validAddr =
          addr:
          builtins.isString addr
          && builtins.match "([0-9]{1,3}\\.){3}[0-9]{1,3}" addr != null
          && builtins.all (octet: pkgs.lib.toInt octet <= 255) (
            builtins.filter builtins.isString (builtins.split "\\." addr)
          );
        normalize =
          entry:
          if builtins.isInt entry then
            {
              port = entry;
              bindAddr = "127.0.0.1";
            }
          else if builtins.isAttrs entry then
            {
              port = entry.port or null;
              bindAddr = entry.bindAddr or "127.0.0.1";
            }
          else
            {
              port = null;
              bindAddr = null;
            };
        normalized = map normalize publishedPorts;
        invalid = builtins.filter (entry: !(validPort entry.port) || !(validAddr entry.bindAddr)) normalized;
      in
      if invalid != [ ] then
        builtins.throw "${errorPrefix} publishedPorts entries must be integers from 1 to 65535 or { port = <1-65535>; bindAddr = \"<ipv4>\"; }. Invalid: ${builtins.toJSON invalid}"
      else
        pkgs.lib.unique normalized;
  # Raised on macOS too, where the combination would technically work, so
  # the two platforms accept the same configurations.
  validateAllowUnixSockets =
    { allowNix, allowUnixSockets }:
    if !(builtins.isBool allowUnixSockets) then
      builtins.throw "${errorPrefix} allowUnixSockets must be a boolean"
    else if allowNix && !allowUnixSockets then
      builtins.throw "${errorPrefix} allowNix = true requires allowUnixSockets = true: the nix daemon is reached over an AF_UNIX socket, which the sandbox denies by default."
    else
      allowUnixSockets;
  assertNoLegacyArgs =
    {
      restrictNetwork,
      extraEnv,
      stateDirs,
      stateFiles,
      allowedLocalPorts,
    }:
    let
      legacyArgHints = {
        allowedLocalPorts =
          if allowedLocalPorts != null then
            "- The 'allowedLocalPorts' argument is deprecated. Use 'allowedHostPorts' instead."
          else
            null;
        restrictNetwork =
          if restrictNetwork != null then
            "- The 'restrictNetwork' argument is deprecated. Network access is controlled by 'allowedDomains': omit it for open internet, set a list/attrset to filter, or [] to block all."
          else
            null;
        extraEnv =
          if extraEnv != null then "- The 'extraEnv' argument is deprecated. Use 'env' instead." else null;
        stateDirs =
          if stateDirs != null then
            "- The 'stateDirs' argument is deprecated. Use 'rwDirs' instead."
          else
            null;
        stateFiles =
          if stateFiles != null then
            "- The 'stateFiles' argument is deprecated. Use 'rwFiles' instead."
          else
            null;
      };
      throwMsgHints = builtins.concatStringsSep "\n" (
        builtins.attrValues (pkgs.lib.filterAttrs (_: v: v != null) legacyArgHints)
      );
      throwMsg = "${errorPrefix} Deprecated arguments:\n\n${throwMsgHints}\n\nMigration guide: https://github.com/archie-judd/agent-sandbox.nix/blob/main/README.md#v0x-to-v1x-migration-guide";
    in
    if
      restrictNetwork != null
      || extraEnv != null
      || stateDirs != null
      || stateFiles != null
      || allowedLocalPorts != null
    then
      builtins.throw throwMsg
    else
      null;

  preEntryScript = pkgs.writeShellScript "pre-entry-script" (builtins.readFile ./pre-entry-script.sh);

  # __pycache__ would otherwise change the store hash from one build to the
  # next depending on whether anything had imported the package in place.
  launcherSource = builtins.filterSource (path: type: baseNameOf path != "__pycache__") ../launcher;

  launcherPackage = pkgs.runCommand "agent-sandbox-launcher" { } ''
    mkdir -p $out
    cp -r ${launcherSource} $out/launcher
  '';

  mkImplicitPackages =
    allowNix:
    [
      pkgs.cacert
      bashWrapper
    ]
    ++ (if allowNix then [ pkgs.nix ] else [ ]);

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

  mkStub =
    { spec, envFragment }:
    pkgs.replaceVars ./stub.sh {
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
      stub,
      buildSpec,
      legacyArgs,
      allowedHostPorts,
      publishedPorts,
      allowUnixSockets,
    }:
    builtins.seq (assertNoLegacyArgs legacyArgs) (
      builtins.seq allowedHostPorts (
        builtins.seq publishedPorts (
          builtins.seq allowUnixSockets (
            pkgs.runCommand outName { } ''
              mkdir -p $out/bin
              install -m755 ${stub} $out/bin/${outName}
            ''
            // {
              buildSpec = buildSpec;
            }
          )
        )
      )
    );
in
{
  bashWrapper = bashWrapper;
  mkAllowlistFile = mkAllowlistFile;
  sandboxProxy = sandboxProxy;
  assertNoLegacyArgs = assertNoLegacyArgs;
  validateAllowedHostPorts = validateAllowedHostPorts;
  validatePublishedPorts = validatePublishedPorts;
  validateAllowUnixSockets = validateAllowUnixSockets;
  preEntryScript = preEntryScript;
  launcherPackage = launcherPackage;
  mkImplicitPackages = mkImplicitPackages;
  mkEnvFragment = mkEnvFragment;
  mkStub = mkStub;
  mkWrapper = mkWrapper;
}
