{ pkgs }:
let
  # Standard stderr message prefixes. Used by all wrapper-emitted warnings and
  # errors so they are visually distinct from the sandboxed program's own
  # output and greppable from interleaved logs.
  warnPrefix = "[WARN][agent-sandbox.nix]";
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
  mkRedirectsEnvBashStr =
    redirects:
    if redirects == { } then
      ""
    else
      let
        entries = pkgs.lib.mapAttrsToList (host: addr: "${host}=${addr}") redirects;
        joined = builtins.concatStringsSep "," entries;
      in
      ''SANDBOX_PROXY_REDIRECT="${joined}" '';
  # Shared by mkLinuxSandbox and mkDarwinSandbox. Starts the MITM proxy,
  # blocks until it reports its listening port via a FIFO, and creates
  # a combined CA bundle for the sandbox to trust the proxy's ephemeral CA.
  mkProxyStartupBashStr =
    allowlistFileStr: listenAddr: redirects:
    # bash
    ''
      # Start the MITM proxy and read its port via FIFO
      _CA_CERT_FILE=$(mktemp /tmp/sandbox-ca-cert.XXXXXX)
      _PROXY_PORT_FIFO=$(mktemp -u /tmp/sandbox-proxy-port.XXXXXX)
      mkfifo "$_PROXY_PORT_FIFO"
      # Open FIFO read-write so neither side blocks waiting for the other
      exec 3<> "$_PROXY_PORT_FIFO"
      ${mkRedirectsEnvBashStr redirects}${sandboxProxy}/bin/sandbox-proxy ${allowlistFileStr} "$_CA_CERT_FILE" ${listenAddr} > "$_PROXY_PORT_FIFO" 2>>/tmp/sandbox-proxy.log &
      _PROXY_PID=$!
      # Block until the proxy writes its port (or 5s timeout via background kill)
      ( sleep 5 && kill -0 $$ 2>/dev/null && echo >&2 "${errorPrefix} sandbox proxy timed out" && kill $$ ) &
      _TIMEOUT_PID=$!
      _PROXY_PORT=$(head -1 <&3)
      exec 3<&-
      kill $_TIMEOUT_PID 2>/dev/null
      wait $_TIMEOUT_PID 2>/dev/null || true
      rm -f "$_PROXY_PORT_FIFO"
      if [ -z "$_PROXY_PORT" ]; then
        echo "${errorPrefix} sandbox proxy failed to start (check /tmp/sandbox-proxy.log)" >&2
        kill $_PROXY_PID 2>/dev/null
        exit 1
      fi
      # Create a combined CA bundle: system certs + proxy's ephemeral CA
      _COMBINED_CA_BUNDLE=$(mktemp /tmp/sandbox-ca-bundle.XXXXXX)
      cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$_CA_CERT_FILE" > "$_COMBINED_CA_BUNDLE"
    '';
  # Emits a bash snippet that checks every declared rwDir / rwFile exists on
  # the host before the sandbox launches. Missing paths are accumulated and
  # reported in one go; the snippet exits 1 if any were missing. Uses
  # `[ -e ]` so a broken symlink also counts as missing — the wrapper used
  # to silently `mkdir -p` / `touch` declared paths, which masked typos
  # like `rwDirs = [ "$HOME/.cluade" ]` as new state directories. The
  # check is emitted as bash (not evaluated in Nix) because paths reference
  # shell vars (`$HOME`, etc.) that are only resolved at runtime.
  assertBindsExistBashStr =
    {
      rwDirs,
      rwFiles,
      roDirs ? [ ],
      roFiles ? [ ],
    }:
    let
      mkCheck =
        label: p:
        # bash
        ''
          if [ ! -e "${p}" ]; then
            echo "${errorPrefix} ${p}: declared as ${label} but does not exist" >&2
            _BIND_MISSING=1
          fi'';
      allChecks = builtins.concatStringsSep "\n" (
        map (mkCheck "rwDir") rwDirs
        ++ map (mkCheck "rwFile") rwFiles
        ++ map (mkCheck "roDir") roDirs
        ++ map (mkCheck "roFile") roFiles
      );
    in
    # bash
    ''
      _BIND_MISSING=0
      ${allChecks}
      if [ "$_BIND_MISSING" -ne 0 ]; then
        exit 1
      fi
    '';
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
  mkProxyStartupBashStr = mkProxyStartupBashStr;
  warnPrefix = warnPrefix;
  errorPrefix = errorPrefix;
  assertNoLegacyArgs = assertNoLegacyArgs;
  validateAllowedLocalPorts = validateAllowedLocalPorts;
  assertBindsExistBashStr = assertBindsExistBashStr;
}
