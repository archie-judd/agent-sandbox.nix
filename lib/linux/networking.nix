{
  pkgs,
  shared,
  restrictNetwork,
  allowedDomains,
  allowedLocalPorts,
  _proxyRedirects ? { },
}:
let
  mkAllowlistFile = shared.mkAllowlistFile;
  mkProxyStartupBashStr = shared.mkProxyStartupBashStr;
  pastaGatewayIp = "10.0.2.2";
  pastaNamespaceIp = "10.0.2.1";
  localNet =
    if allowedLocalPorts == [ ] then
      {
        natSetup = "";
        acceptRules = "";
      }
    else
      let
        tcpPortMatches =
          if allowedLocalPorts == null then
            [ "tcp" ]
          else
            map (port: "tcp dport ${toString port}") allowedLocalPorts;
        dnatRules = builtins.concatStringsSep "\n" (
          map (match: ''$NFT add rule ip sandbox_nat output ip daddr 127.0.0.1 ${match} dnat to ${pastaGatewayIp}'') tcpPortMatches
        );
        snatRules = builtins.concatStringsSep "\n" (
          map (match: ''$NFT add rule ip sandbox_nat postrouting ip saddr 127.0.0.1 ip daddr ${pastaGatewayIp} ${match} masquerade'') tcpPortMatches
        );
      in
      {
        natSetup =
          # bash
          ''
            # DNAT from sandbox localhost needs route_localnet, and the translated
            # flow needs SNAT so pasta sees it as coming from the namespace address.
            echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet
            echo 1 > /proc/sys/net/ipv4/conf/default/route_localnet
            $NFT add table ip sandbox_nat
            $NFT add chain ip sandbox_nat output '{ type nat hook output priority -100 ; policy accept ; }'
            $NFT add chain ip sandbox_nat postrouting '{ type nat hook postrouting priority 100 ; policy accept ; }'
            ${dnatRules}
            ${snatRules}
          '';
        acceptRules = builtins.concatStringsSep "\n" (
          map (match: ''$NFT add rule ip sandbox_filter output ip daddr ${pastaGatewayIp} ${match} accept'') tcpPortMatches
        );
      };
  # Runs inside pasta's namespace (before bwrap) in open (allowedDomains=null)
  # mode. Keeps the default route so the sandbox can reach the internet, but
  # drops the pasta gateway IP except for explicit allowedLocalPorts.
  # pasta forwards 10.0.2.2:<port> → 127.0.0.1:<port> on the host, so dropping
  # traffic to that address blocks host loopback services (databases, dev
  # servers, ssh-agent, etc.) without touching internet traffic (whose
  # destination IPs are real server addresses, not 10.0.2.2).
  openModeRouteRestrictScript =
    pkgs.writeScript "sandbox-open-route-restrict"
      # bash
      ''
        #!${pkgs.bashInteractive}/bin/bash
        set -euo pipefail
        NFT="${pkgs.nftables}/bin/nft"
        $NFT add table ip sandbox_filter
        $NFT add chain ip sandbox_filter output '{ type filter hook output priority 0 ; policy accept ; }'
        ${localNet.natSetup}
        ${localNet.acceptRules}
        $NFT add rule ip sandbox_filter output ip daddr ${pastaGatewayIp} drop
        exec "$@"
      '';
  # Route-restriction script runs inside pasta's namespace (before bwrap).
  # Removes the default route so the namespace cannot reach the wider
  # internet directly. The proxy is bound on 127.0.0.1 on the host;
  # pasta forwards 10.0.2.2:<port> → 127.0.0.1:<port>, so the sandbox
  # only needs to reach the pasta gateway — the host LAN IP is never needed.
  # Installs an nftables OUTPUT chain with default-drop policy. Only
  # in-namespace loopback and TCP to the proxy port on the pasta gateway
  # are accepted — all other protocols (UDP, ICMP, …) and non-proxy TCP
  # ports are blocked.
  routeRestrictScript =
    pkgs.writeScript "sandbox-route-restrict"
      # bash
      ''
        #!${pkgs.bashInteractive}/bin/bash
        set -euo pipefail
        IP="${pkgs.iproute2}/bin/ip"
        NFT="${pkgs.nftables}/bin/nft"
        $IP route del default || { echo "${shared.errorPrefix} could not remove default route" >&2; exit 1; }
        $NFT add table ip sandbox_filter
        $NFT add chain ip sandbox_filter output '{ type filter hook output priority 0 ; policy drop ; }'
        $NFT add rule ip sandbox_filter output oif lo accept
        ${localNet.natSetup}
        $NFT add rule ip sandbox_filter output ip daddr ${pastaGatewayIp} tcp dport "$SANDBOX_PROXY_PORT" accept
        ${localNet.acceptRules}
        exec "$@"
      '';
in
if restrictNetwork then
  let
    allowlistFileStr = mkAllowlistFile allowedDomains;
  in
  {
    proxyEnvBubblewrapStr = ''--setenv HTTP_PROXY "http://${pastaGatewayIp}:$_PROXY_PORT" --setenv HTTPS_PROXY "http://${pastaGatewayIp}:$_PROXY_PORT" --setenv http_proxy "http://${pastaGatewayIp}:$_PROXY_PORT" --setenv https_proxy "http://${pastaGatewayIp}:$_PROXY_PORT"'';

    caCertBubblewrapStr = ''--ro-bind "$_COMBINED_CA_BUNDLE" /tmp/sandbox-ca-bundle.pem --ro-bind "$_CA_CERT_FILE" /tmp/sandbox-ca-cert.pem --setenv SSL_CERT_FILE /tmp/sandbox-ca-bundle.pem --setenv NIX_SSL_CERT_FILE /tmp/sandbox-ca-bundle.pem --setenv NODE_EXTRA_CA_CERTS /tmp/sandbox-ca-cert.pem --setenv REQUESTS_CA_BUNDLE /tmp/sandbox-ca-bundle.pem'';
    proxyStartupBashStr = mkProxyStartupBashStr allowlistFileStr "127.0.0.1" _proxyRedirects;

    bashCleanupCommandsStr =
      # bash
      ''kill $_PROXY_PID 2>/dev/null; rm -f "$_CA_CERT_FILE" "$_COMBINED_CA_BUNDLE"'';

    sandboxExecBashStr = # bash
      ''SANDBOX_PROXY_PORT="$_PROXY_PORT" ${pkgs.passt}/bin/pasta -4 --config-net -a ${pastaNamespaceIp} -g ${pastaGatewayIp} -n 255.255.255.0 -t none -u none -T none -U none -- ${routeRestrictScript} '';
    etcResolvBind = "--ro-bind /dev/null /etc/resolv.conf"; # Block DNS resolution when restrictNetwork is true.
    resolvConfSetupBashStr = "";
    sslCertEnvBubblewrapStr = ""; # CA cert env vars are set in caCertBubblewrapStr
  }
else
  {
    proxyEnvBubblewrapStr = "";
    caCertBubblewrapStr = "";
    proxyStartupBashStr = "";
    bashCleanupCommandsStr = "";
    sandboxExecBashStr = # bash
      ''${pkgs.passt}/bin/pasta -4 --config-net -a ${pastaNamespaceIp} -g ${pastaGatewayIp} -n 255.255.255.0 -t none -u none -T none -U none -- ${openModeRouteRestrictScript} '';

    # On systems using systemd-resolved (e.g. Ubuntu), /etc/resolv.conf points
    # to 127.0.0.53 — the stub listener on the host's loopback. Inside the
    # pasta namespace that address is the namespace's own loopback with nothing
    # listening, so DNS breaks. /run/systemd/resolve/resolv.conf holds the real
    # upstream IPs that systemd-resolved forwards to; those are routable from
    # the namespace via the default route. On NixOS /etc/resolv.conf already
    # has real IPs so the fallback is a no-op.
    resolvConfSetupBashStr =
      # bash
      ''
        _RESOLV_CONF=/etc/resolv.conf
        if grep -qEm1 '^nameserver[[:space:]]+(127\.|::1)' /etc/resolv.conf 2>/dev/null \
           && [ -f /run/systemd/resolve/resolv.conf ]; then
          _RESOLV_CONF=/run/systemd/resolve/resolv.conf
        fi
      '';
    etcResolvBind = ''--ro-bind "$_RESOLV_CONF" /etc/resolv.conf'';

    sslCertEnvBubblewrapStr = ''--setenv SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" --setenv NIX_SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"'';
  }
