{ pkgs, shared, restrictNetwork, allowedDomains, _proxyRedirects ? { } }:
let
  mkAllowlistFile = shared.mkAllowlistFile;
  hasAllowedDomains = shared.hasAllowedDomains;
  mkProxyStartupBashStr = shared.mkProxyStartupBashStr;
  # Route-restriction script runs inside pasta's namespace (before bwrap).
  # Removes the default route and adds a host-only route so the namespace
  # can only reach the host machine (where the proxy listens), not the
  # wider internet.
  # Also installs an nftables OUTPUT rule that restricts TCP to the host to
  # the proxy port only, preventing direct access to other host services
  # (SSH, databases, dev servers, etc.) on the same machine.
  routeRestrictScript = pkgs.writeScript "sandbox-route-restrict" ''
    #!${pkgs.bashInteractive}/bin/bash
    set -euo pipefail
    IP="${pkgs.iproute2}/bin/ip"
    NFT="${pkgs.nftables}/bin/nft"
    $IP route del default || { echo "FATAL: could not remove default route" >&2; exit 1; }
    $IP route add "$SANDBOX_HOST_IP"/32 via 10.0.2.2 || { echo "FATAL: could not add host route" >&2; exit 1; }
    $NFT add table ip sandbox_filter
    $NFT add chain ip sandbox_filter output '{ type filter hook output priority 0 ; policy accept ; }'
    $NFT add rule ip sandbox_filter output ip daddr "$SANDBOX_HOST_IP" tcp dport != "$SANDBOX_PROXY_PORT" drop
    exec "$@"
  '';
in if restrictNetwork then
  let allowlistFileStr = mkAllowlistFile allowedDomains;
  in {
    warnIgnoredDomainsBashStr = "";
    proxyEnvBubblewrapStr = ''
      --setenv HTTP_PROXY "http://$_HOST_IP:$_PROXY_PORT" --setenv HTTPS_PROXY "http://$_HOST_IP:$_PROXY_PORT" --setenv http_proxy "http://$_HOST_IP:$_PROXY_PORT" --setenv https_proxy "http://$_HOST_IP:$_PROXY_PORT"'';

    caCertBubblewrapStr = ''
      --ro-bind "$_COMBINED_CA_BUNDLE" /tmp/sandbox-ca-bundle.pem --ro-bind "$_CA_CERT_FILE" /tmp/sandbox-ca-cert.pem --setenv SSL_CERT_FILE /tmp/sandbox-ca-bundle.pem --setenv NIX_SSL_CERT_FILE /tmp/sandbox-ca-bundle.pem --setenv NODE_EXTRA_CA_CERTS /tmp/sandbox-ca-cert.pem --setenv REQUESTS_CA_BUNDLE /tmp/sandbox-ca-bundle.pem'';
    proxyStartupBashStr = ''
      # Detect host IP so the pasta namespace can reach the proxy
      _HOST_IP=$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'src \K\S+')
      if [ -z "$_HOST_IP" ]; then
        echo "ERROR: could not determine host IP for pasta network namespace" >&2
        exit 1
      fi
    '' + mkProxyStartupBashStr allowlistFileStr "$_HOST_IP" _proxyRedirects;

    bashTrapCleanupStr = ''
      trap 'kill $_PROXY_PID 2>/dev/null; rm -f "$_CA_CERT_FILE" "$_COMBINED_CA_BUNDLE"' EXIT'';

    sandboxExecBashStr = ''
      SANDBOX_HOST_IP="$_HOST_IP" SANDBOX_PROXY_PORT="$_PROXY_PORT" ${pkgs.passt}/bin/pasta -4 --config-net -a 10.0.2.1 -g 10.0.2.2 -n 255.255.255.0 -t none -u none -T none -U none -- ${routeRestrictScript} '';
    etcResolvBind =
      "--ro-bind /dev/null /etc/resolv.conf"; # Block DNS resolution when restrictNetwork is true.
    sslCertEnvBubblewrapStr =
      ""; # CA cert env vars are set in caCertBubblewrapStr
  }
else {
  warnIgnoredDomainsBashStr = if (hasAllowedDomains allowedDomains) then ''
    echo "WARNING: allowedDomains is set but restrictNetwork is false — domains will be ignored" >&2
  '' else
    "";
  proxyEnvBubblewrapStr = "";
  caCertBubblewrapStr = "";
  proxyStartupBashStr = "";
  bashTrapCleanupStr = "";
  sandboxExecBashStr = "exec ";

  etcResolvBind =
    "--ro-bind /etc/resolv.conf /etc/resolv.conf"; # Normal DNS resolution when restrictNetwork is false.

  sslCertEnvBubblewrapStr = ''
    --setenv SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" --setenv NIX_SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"'';
}
