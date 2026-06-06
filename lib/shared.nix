{ pkgs }:
let
  sandboxProxy = import ../proxy { pkgs = pkgs; };
  # Wrapper that forces --norc --noprofile on every bash invocation.
  # Newer claude-code versions spawn bash as a login/interactive shell,
  # which causes it to source /etc/bashrc and /etc/profile. This wrapper
  # intercepts any bash call (whether via SHELL, /bin/sh, or direct exec)
  # and strips that behaviour regardless of how the caller invokes it.
  bashWrapper = pkgs.runCommand "bash-norc" {
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
  } ''
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
  mkAllowlistFile = allowedDomains:
    let
      attrset = if builtins.isList allowedDomains then
        builtins.listToAttrs (map (d: {
          name = d;
          value = "*";
        }) allowedDomains)
      else
        allowedDomains;
    in pkgs.writeText "sandbox-allowlist.json" (builtins.toJSON attrset);
  # Returns true if allowedDomains is non-empty (works for both list and attrset).
  hasAllowedDomains = allowedDomains:
    if builtins.isList allowedDomains then
      allowedDomains != [ ]
    else
      allowedDomains != { };
  # Internal: serializes _proxyRedirects ({ host = "addr:port"; ... }) to the
  # SANDBOX_PROXY_REDIRECT env var value the proxy expects. Empty redirects
  # produces an empty string so the env var is not set at all in production.
  mkRedirectsEnvBashStr = redirects:
    if redirects == { } then
      ""
    else
      let
        entries =
          pkgs.lib.mapAttrsToList (host: addr: "${host}=${addr}") redirects;
        joined = builtins.concatStringsSep "," entries;
      in ''SANDBOX_PROXY_REDIRECT="${joined}" '';
  # Shared by mkLinuxSandbox and mkDarwinSandbox. Starts the MITM proxy,
  # blocks until it reports its listening port via a FIFO, and creates
  # a combined CA bundle for the sandbox to trust the proxy's ephemeral CA.
  mkProxyStartupBashStr = allowlistFileStr: listenAddr: redirects: ''
    # Start the MITM proxy and read its port via FIFO
    _CA_CERT_FILE=$(mktemp /tmp/sandbox-ca-cert.XXXXXX)
    _PROXY_PORT_FIFO=$(mktemp -u /tmp/sandbox-proxy-port.XXXXXX)
    mkfifo "$_PROXY_PORT_FIFO"
    # Open FIFO read-write so neither side blocks waiting for the other
    exec 3<> "$_PROXY_PORT_FIFO"
    ${mkRedirectsEnvBashStr redirects}${sandboxProxy}/bin/sandbox-proxy ${allowlistFileStr} "$_CA_CERT_FILE" ${listenAddr} > "$_PROXY_PORT_FIFO" 2>>/tmp/sandbox-proxy.log &
    _PROXY_PID=$!
    # Block until the proxy writes its port (or 5s timeout via background kill)
    ( sleep 5 && kill -0 $$ 2>/dev/null && echo >&2 "ERROR: sandbox proxy timed out" && kill $$ ) &
    _TIMEOUT_PID=$!
    _PROXY_PORT=$(head -1 <&3)
    exec 3<&-
    kill $_TIMEOUT_PID 2>/dev/null
    wait $_TIMEOUT_PID 2>/dev/null || true
    rm -f "$_PROXY_PORT_FIFO"
    if [ -z "$_PROXY_PORT" ]; then
      echo "ERROR: sandbox proxy failed to start (check /tmp/sandbox-proxy.log)" >&2
      kill $_PROXY_PID 2>/dev/null
      exit 1
    fi
    # Create a combined CA bundle: system certs + proxy's ephemeral CA
    _COMBINED_CA_BUNDLE=$(mktemp /tmp/sandbox-ca-bundle.XXXXXX)
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$_CA_CERT_FILE" > "$_COMBINED_CA_BUNDLE"
  '';
in {
  bashWrapper = bashWrapper;
  mkAllowlistFile = mkAllowlistFile;
  hasAllowedDomains = hasAllowedDomains;
  mkProxyStartupBashStr = mkProxyStartupBashStr;
}
