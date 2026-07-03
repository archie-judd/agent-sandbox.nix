{
  pkgs,
  shared,
  allowedDomains,
  allowedLocalPorts,
  _proxyRedirects ? { },
}:
let
  mkAllowlistFile = shared.mkAllowlistFile;
  mkProxyStartupBashStr = shared.mkProxyStartupBashStr;
  darwinAllowedLocalPortsRulesStr = builtins.concatStringsSep "\n" (
    map (port: ''        (allow network-outbound (remote ip "localhost:${toString port}"))'') allowedLocalPorts
  );
in
if allowedDomains != null then
  let
    allowlistFileStr = mkAllowlistFile allowedDomains;
  in
  {
    proxyEnvInlineBashStr =
      # bash
      ''HTTP_PROXY="http://127.0.0.1:$_PROXY_PORT" HTTPS_PROXY="http://127.0.0.1:$_PROXY_PORT" http_proxy="http://127.0.0.1:$_PROXY_PORT" https_proxy="http://127.0.0.1:$_PROXY_PORT"'';
    caCertEnvInlineBashStr =
      # bash
      ''SSL_CERT_FILE="$_COMBINED_CA_BUNDLE" NIX_SSL_CERT_FILE="$_COMBINED_CA_BUNDLE" NODE_EXTRA_CA_CERTS="$_CA_CERT_FILE" REQUESTS_CA_BUNDLE="$_COMBINED_CA_BUNDLE"'';
    networkSeatbeltRulesStr =
      # scheme
      ''
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
        ${darwinAllowedLocalPortsRulesStr}
      '';
    proxyStartupBashStr = mkProxyStartupBashStr allowlistFileStr "127.0.0.1" _proxyRedirects;
    networkRuntimePatchBashStr =
      # bash
      ''
        printf '    (allow network-outbound (remote ip "localhost:%s"))\n' "$_PROXY_PORT" >> "$SANDBOX_PROFILE"
      '';
    bashTrapCleanupStr =
      # bash
      ''
        trap 'kill $_PROXY_PID 2>/dev/null; rm -f "$_CA_CERT_FILE" "$_COMBINED_CA_BUNDLE"; rm -f "$_SANDBOX_PASSWD"; rm -rf "$SANDBOX_HOME" "$SANDBOX_PROFILE"' EXIT
      '';
    sandboxExecBashStr = "";
  }
else
  {
    proxyEnvInlineBashStr = "";
    caCertEnvInlineBashStr =
      # bash
      ''SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" NIX_SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"'';
    networkSeatbeltRulesStr =
      # scheme
      ''
        ;; Network. (allow network*) is permissive across bind/inbound/
        ;; outbound and across IP families and protocols (including AF_UNIX
        ;; outbound). The two scoped denies below narrow it to match the
        ;; README's "no local services" promise:
        ;;
        ;;   - The IP-loopback deny blocks connect() to 127.0.0.0/8 and
        ;;     ::1 (one rule covers both — verified). Host loopback
        ;;     services (Postgres, dev servers, the SSH agent over TCP,
        ;;     local API mocks, etc.) are unreachable in open mode.
        ;;
        ;;   - The unix-socket deny blocks AF_UNIX connect() to host UNIX
        ;;     sockets (Alacritty IPC, per-user launchd listeners under
        ;;     /private/tmp, ssh-agent). Nothing the sandbox ships needs
        ;;     UNIX-socket egress.
        ;;
        ;; seatbelt is last-match-wins, so the denies override the earlier
        ;; (allow network*). The filtered branch reaches the same
        ;; loopback/UNIX-deny end state by a different mechanism: it never
        ;; grants (allow network*) in the first place, only a proxy-port-
        ;; pinned (allow network-outbound (remote ip "localhost:<port>")).
        ;;
        ;; (allow system-socket) — kept; it gates socket(PF_SYSTEM, ...)
        ;; (kernel-control sockets, utun, etc.), not AF_UNIX, and matches
        ;; what the filtered branch grants.
        ;;
        ;; mDNSResponder exception: macOS getaddrinfo() resolves names via
        ;; /private/var/run/mDNSResponder (AF_UNIX). The blanket unix-socket
        ;; deny above would kill all in-sandbox DNS — curl, git over HTTPS,
        ;; etc. — so we re-allow that one path. The deny still wins for
        ;; every other AF_UNIX target (ssh-agent, terminal IPC, app
        ;; sockets under /private/tmp, …). Filtered mode doesn't need this
        ;; exception because the proxy resolves names; the sandbox there
        ;; only dials TCP to localhost:<proxy-port>.
        (allow network*)
        (allow system-socket)
        (deny network-outbound (remote ip "localhost:*"))
        (deny network-outbound (remote unix-socket))
        (allow network-outbound
          (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
        ${darwinAllowedLocalPortsRulesStr}
      '';
    proxyStartupBashStr = "";
    networkRuntimePatchBashStr = "";
    bashTrapCleanupStr =
      # bash
      ''
        trap 'rm -f "$_SANDBOX_PASSWD"; rm -rf "$SANDBOX_HOME" "$SANDBOX_PROFILE"' EXIT
      '';
    sandboxExecBashStr = "exec ";
  }
