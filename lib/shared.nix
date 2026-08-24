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
  # Internal: serializes _proxyRedirects ({ host = "addr:port"; ... }) to the
  # SANDBOX_PROXY_REDIRECT env var value the proxy expects. Empty redirects
  # produces an empty string so the env var is not set at all in production.
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
in
{
  bashWrapper = bashWrapper;
  mkAllowlistFile = mkAllowlistFile;
  sandboxProxy = sandboxProxy;
  assertNoLegacyArgs = assertNoLegacyArgs;
  validateAllowedLocalPorts = validateAllowedLocalPorts;
}
