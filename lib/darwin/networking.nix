{ pkgs, shared, restrictNetwork, allowedDomains, _proxyRedirects ? { } }:
let
  mkAllowlistFile = shared.mkAllowlistFile;
  hasAllowedDomains = shared.hasAllowedDomains;
  mkProxyStartupBashStr = shared.mkProxyStartupBashStr;
in if restrictNetwork then
  let allowlistFileStr = mkAllowlistFile allowedDomains;
  in {
    warnIgnoredDomainsBashStr = "";
    proxyEnvInlineBashStr = ''
      HTTP_PROXY="http://127.0.0.1:$_PROXY_PORT" HTTPS_PROXY="http://127.0.0.1:$_PROXY_PORT" http_proxy="http://127.0.0.1:$_PROXY_PORT" https_proxy="http://127.0.0.1:$_PROXY_PORT"'';
    caCertEnvInlineBashStr = ''
      SSL_CERT_FILE="$_COMBINED_CA_BUNDLE" NIX_SSL_CERT_FILE="$_COMBINED_CA_BUNDLE" NODE_EXTRA_CA_CERTS="$_CA_CERT_FILE" REQUESTS_CA_BUNDLE="$_COMBINED_CA_BUNDLE"'';
    networkSeatbeltRulesStr = ''
      ;; Network — restricted to localhost only (proxy-based domain filtering).
      ;; The outbound localhost rule is appended at runtime by
      ;; networkRuntimePatchBashStr once the proxy port is known, so it can
      ;; be pinned to that specific port. This prevents the sandbox from
      ;; reaching other loopback services (local databases, dev servers,
      ;; etc.) directly, bypassing the proxy's domain/method filtering.
      ;;
      ;; UNIX-socket egress is intentionally NOT allowed: an unrestricted
      ;; (remote unix-socket) allow lets the sandboxed process connect()
      ;; to any UNIX socket the host UID can reach (terminal-emulator IPC
      ;; like Alacritty, per-user launchd listeners under /private/tmp,
      ;; ssh-agent, etc.). The proxy speaks TCP, so nothing legitimate
      ;; needs UNIX-socket egress.
      (allow network-bind (local ip "localhost:*"))
      (allow system-socket)
    '';
    proxyStartupBashStr =
      mkProxyStartupBashStr allowlistFileStr "127.0.0.1" _proxyRedirects;
    networkRuntimePatchBashStr = ''
      printf '    (allow network-outbound (remote ip "localhost:%s"))\n' "$_PROXY_PORT" >> "$SANDBOX_PROFILE"
    '';
    bashTrapCleanupStr = ''
      trap 'kill $_PROXY_PID 2>/dev/null; rm -f "$_CA_CERT_FILE" "$_COMBINED_CA_BUNDLE"; rm -f "$_SANDBOX_PASSWD"; rm -rf "$SANDBOX_HOME" "$SANDBOX_PROFILE"' EXIT'';
    sandboxExecBashStr = "";
  }
else {
  warnIgnoredDomainsBashStr = if (hasAllowedDomains allowedDomains) then ''
    echo "WARNING: allowedDomains is set but restrictNetwork is false — domains will be ignored" >&2
  '' else
    "";
  proxyEnvInlineBashStr = "";
  caCertEnvInlineBashStr = ''
    SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" NIX_SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"'';
  networkSeatbeltRulesStr = ''
    ;; Network
    (allow network*)
    (allow system-socket)
  '';
  proxyStartupBashStr = "";
  networkRuntimePatchBashStr = "";
  bashTrapCleanupStr =
    ''trap 'rm -f "$_SANDBOX_PASSWD"; rm -rf "$SANDBOX_HOME" "$SANDBOX_PROFILE"' EXIT'';
  sandboxExecBashStr = "exec ";
}
