# What both backends need. Two kinds of thing live here: the argument
# validation and closure inputs that are the same on either platform, and the
# machinery that turns a spec into $out/bin/<outName>. lib/linux.nix and
# lib/darwin.nix hold only what actually differs between the two.
{ pkgs }:
let
  # Standard stderr message prefixes. Used by all wrapper-emitted warnings and
  # errors so they are visually distinct from the sandboxed program's own
  # output and greppable from interleaved logs.
  errorPrefix = "[ERROR][agent-sandbox.nix]";
  sandboxProxy = import ../proxy { pkgs = pkgs; };
  # Wrapper that forces --norc --noprofile on every bash invocation.
  # Newer claude-code versions spawn bash as a login/interactive shell,
  # which causes it to source /etc/bashrc and /etc/profile. This wrapper
  # intercepts any bash call (whether via SHELL, /bin/sh, or direct exec)
  # and strips that behaviour regardless of how the caller invokes it.
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
  # Serializes allowedDomains to a JSON config file for the proxy.
  # Accepts two formats:
  #   List (backward compat): [ "github.com" "anthropic.com" ]
  #     → every domain gets "*" (all methods allowed)
  #   Attrset (per-domain method control):
  #     { "*" = [ "GET" "HEAD" ]; "api.anthropic.com" = "*"; }
  # Output JSON: { "domain": "*" | ["GET","HEAD"], ... }
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
  validateAllowedLocalPorts =
    allowedLocalPorts:
    if allowedLocalPorts == null then
      null
    else if !(builtins.isList allowedLocalPorts) then
      builtins.throw "${errorPrefix} allowedLocalPorts must be null or a list of integers from 1 to 65535"
    else
      let
        validPort = port: builtins.isInt port && port >= 1 && port <= 65535;
        invalidPorts = builtins.filter (port: !validPort port) allowedLocalPorts;
      in
      if invalidPorts != [ ] then
        builtins.throw "${errorPrefix} allowedLocalPorts must only contain integers from 1 to 65535. Use null to allow all host-local TCP ports. Invalid port(s): ${builtins.toJSON invalidPorts}"
      else
        pkgs.lib.unique allowedLocalPorts;
  assertNoLegacyArgs =
    {
      restrictNetwork,
      extraEnv,
      stateDirs,
      stateFiles,
    }:
    let
      legacyArgHints = {
        restrictNetwork =
          if restrictNetwork != null then
            "- The 'restrictNetwork' argument is deprecated. Network access is now controlled by 'allowedDomains' alone:\n  - omit it for open internet\n  - set a list/attrset to filter\n  - set to [] to block all"
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
      throwMsg = "${errorPrefix} Deprecated arguments:\n\n${throwMsgHints}\n\nPlease update your configuration accordingly. See the migration guide: https://github.com/archie-judd/agent-sandbox.nix/blob/main/README.md#v0x-to-v1x-migration-guide";
    in
    if restrictNetwork != null || extraEnv != null || stateDirs != null || stateFiles != null then
      builtins.throw throwMsg
    else
      null;

  # Runs inside the sandbox ahead of the agent binary: probes for a declared
  # git identity and warns the user at launch if none is found, then exec's
  # the real command. See lib/pre-entry-script.sh.
  preEntryScript = pkgs.writeShellScript "pre-entry-script" (builtins.readFile ./pre-entry-script.sh);

  # __pycache__ would otherwise change the store hash from one build to the
  # next depending on whether anything had imported the package in place.
  launcherSource = builtins.filterSource (path: type: baseNameOf path != "__pycache__") ../launcher;

  launcherPackage = pkgs.runCommand "agent-sandbox-launcher" { } ''
    mkdir -p $out
    cp -r ${launcherSource} $out/launcher
  '';

  # cacert and bashWrapper are always included: cacert so SSL/TLS verification
  # works, bashWrapper so the hardcoded SHELL and /bin/sh symlink targets are
  # always reachable. bashWrapper forces --norc --noprofile on every bash
  # invocation so the sandboxed process cannot source /etc/bashrc or
  # /etc/profile.
  mkImplicitPackages =
    allowNix:
    [
      pkgs.cacert
      bashWrapper
    ]
    ++ (if allowNix then [ pkgs.nix ] else [ ]);

  # One data line per declared variable, and no logic. The values are
  # documented as runtime shell expressions, both the "$TOKEN" form and the
  # sops "$(cat /run/secrets/...)" form, so they expand in the stub and never
  # enter Python or touch disk.
  #
  # Each line calls declare_env rather than appending to an array directly, so
  # that the expansion happens inside the stub where a failure can be caught and
  # reported against the env attribute it came from. toJSON supplies the double
  # quotes the value expands inside, so a value containing spaces is still one
  # word; escapeShellArg then carries that whole fragment through as a literal
  # argument, unexpanded until declare_env evals it.
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

  # The wrapper itself. Both seqs are what make the validation an eval-time
  # error: nothing else forces them, so without them a deprecated argument or
  # an out-of-range port would only be discovered when the agent is launched.
  mkWrapper =
    {
      outName,
      stub,
      buildSpec,
      legacyArgs,
      allowedLocalPorts,
    }:
    builtins.seq (assertNoLegacyArgs legacyArgs) (
      builtins.seq allowedLocalPorts (
        pkgs.runCommand outName { } ''
          mkdir -p $out/bin
          install -m755 ${stub} $out/bin/${outName}
        ''
        // {
          buildSpec = buildSpec;
        }
      )
    );
in
{
  bashWrapper = bashWrapper;
  mkAllowlistFile = mkAllowlistFile;
  sandboxProxy = sandboxProxy;
  assertNoLegacyArgs = assertNoLegacyArgs;
  validateAllowedLocalPorts = validateAllowedLocalPorts;
  preEntryScript = preEntryScript;
  launcherPackage = launcherPackage;
  mkImplicitPackages = mkImplicitPackages;
  mkEnvFragment = mkEnvFragment;
  mkStub = mkStub;
  mkWrapper = mkWrapper;
}
