{ pkgs, errorPrefix }:
let
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
  validateWorkspaceDir =
    workspaceDir:
    if !(builtins.isString workspaceDir) then
      builtins.throw "${errorPrefix} workspaceDir must be a string holding an absolute path (\"$VAR\" and \"~\" are expanded at launch)"
    else
      let
        firstChar = builtins.substring 0 1 workspaceDir;
      in
      if firstChar != "/" && firstChar != "~" && firstChar != "$" then
        builtins.throw "${errorPrefix} workspaceDir must be an absolute path, or start with \"$\" or \"~\" to be expanded at launch. Invalid: ${builtins.toJSON workspaceDir}"
      else
        workspaceDir;

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
        invalid = builtins.filter (
          entry: !(validPort entry.port) || !(validAddr entry.bindAddr)
        ) normalized;
      in
      if invalid != [ ] then
        builtins.throw "${errorPrefix} publishedPorts entries must be integers from 1 to 65535 or { port = <1-65535>; bindAddr = \"<ipv4>\"; }. Invalid: ${builtins.toJSON invalid}"
      else
        pkgs.lib.unique normalized;
  # Raised on macOS too, where the combination would technically work, so
  # the two platforms accept the same configurations.
  validateAllowUnixSockets =
    {
      allowNix,
      allowUnixSockets,
      allowHeadlessBrowsers,
    }:
    if !(builtins.isBool allowUnixSockets) then
      builtins.throw "${errorPrefix} allowUnixSockets must be a boolean"
    else if allowNix && !allowUnixSockets then
      builtins.throw "${errorPrefix} allowNix = true requires allowUnixSockets = true: the nix daemon is reached over an AF_UNIX socket, which the sandbox denies by default."
    else if pkgs.stdenv.hostPlatform.isLinux && allowHeadlessBrowsers != [ ] && !allowUnixSockets then
      builtins.throw "${errorPrefix} allowHeadlessBrowsers requires allowUnixSockets = true on Linux: browsers lock their profile with a UNIX-domain socket. For a config shared with macOS, set allowUnixSockets = !pkgs.stdenv.hostPlatform.isDarwin."
    else
      allowUnixSockets;

  validateAllowHeadlessBrowsers =
    allowHeadlessBrowsers:
    let
      engines = [
        "chromium"
        "firefox"
      ];
      quoted = builtins.concatStringsSep ", " (map (engine: ''"${engine}"'') engines);
    in
    if !(builtins.isList allowHeadlessBrowsers) then
      builtins.throw "${errorPrefix} allowHeadlessBrowsers must be a list of browser engines (${quoted}), not a boolean or other value"
    else if !(builtins.all (entry: builtins.elem entry engines) allowHeadlessBrowsers) then
      builtins.throw "${errorPrefix} allowHeadlessBrowsers entries must each be one of ${quoted}. Got: ${builtins.toJSON allowHeadlessBrowsers}"
    else if pkgs.lib.unique allowHeadlessBrowsers != allowHeadlessBrowsers then
      builtins.throw "${errorPrefix} allowHeadlessBrowsers must not repeat an engine. Got: ${builtins.toJSON allowHeadlessBrowsers}"
    else
      allowHeadlessBrowsers;

  # The launcher joins these into SANDBOX_PROXY_REDIRECT as "host=addr[,...]"
  # and the proxy splits them back apart, so a "," in either half, or an "="
  # in the host, would forge an entry no caller wrote.
  validateProxyRedirects =
    proxyRedirects:
    if !(builtins.isAttrs proxyRedirects) then
      builtins.throw "${errorPrefix} _proxyRedirects must be an attrset mapping \"host\" to \"addr:port\""
    else
      let
        validHost = host: builtins.match "[^,=]+" host != null;
        validAddr = addr: builtins.isString addr && builtins.match "[^,]+" addr != null;
        invalid = pkgs.lib.filterAttrs (host: addr: !(validHost host) || !(validAddr addr)) proxyRedirects;
      in
      if invalid != { } then
        builtins.throw "${errorPrefix} _proxyRedirects hosts must not contain \",\" or \"=\", and addresses must not contain \",\". Invalid: ${builtins.toJSON invalid}"
      else
        proxyRedirects;
  validateInjectedCredentials =
    {
      injectedCredentials,
      env,
      allowedDomains,
    }:
    let
      lower = pkgs.lib.toLower;
      domainKeys =
        if builtins.isList allowedDomains then
          allowedDomains
        else if builtins.isAttrs allowedDomains then
          builtins.attrNames allowedDomains
        else
          [ ];
      domainHosts = map (key: lower (builtins.head (builtins.split "/" key))) domainKeys;
      hostAllowed =
        host:
        builtins.any (
          domain: domain == "*" || domain == lower host || pkgs.lib.hasSuffix ".${domain}" (lower host)
        ) domainHosts;
      schemeFields = {
        bearer = [ "scheme" ];
        basic = [
          "scheme"
          "username"
        ];
        header = [
          "scheme"
          "header"
        ];
      };
      validHostEntry =
        entry:
        builtins.isAttrs entry
        && builtins.isString (entry.scheme or null)
        && builtins.hasAttr entry.scheme schemeFields
        && builtins.attrNames entry == builtins.sort builtins.lessThan schemeFields.${entry.scheme}
        && builtins.all (field: builtins.isString entry.${field} && entry.${field} != "") (
          builtins.attrNames entry
        );
      validEntry =
        entry:
        builtins.isAttrs entry
        && builtins.attrNames entry == [
          "hosts"
          "placeholder"
          "secret"
        ]
        && builtins.isString entry.secret
        && entry.secret != ""
        && builtins.isString entry.placeholder
        && entry.placeholder != ""
        && builtins.isAttrs entry.hosts
        && entry.hosts != { }
        && builtins.all validHostEntry (builtins.attrValues entry.hosts);
      names = builtins.attrNames injectedCredentials;
      invalidNames = builtins.filter (name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name == null) names;
      invalidEntries = builtins.filter (name: !(validEntry injectedCredentials.${name})) names;
      envClashes = builtins.filter (name: builtins.hasAttr name env) names;
      hosts = builtins.concatMap (
        name: map lower (builtins.attrNames injectedCredentials.${name}.hosts)
      ) names;
      duplicateHosts = pkgs.lib.unique (
        builtins.filter (host: builtins.length (builtins.filter (other: other == host) hosts) > 1) hosts
      );
      unallowedHosts = builtins.filter (host: !(hostAllowed host)) hosts;
    in
    if !(builtins.isAttrs injectedCredentials) then
      builtins.throw "${errorPrefix} injectedCredentials must be an attrset mapping an env var name to { secret, placeholder, hosts }"
    else if injectedCredentials == { } then
      injectedCredentials
    else if allowedDomains == null then
      builtins.throw "${errorPrefix} injectedCredentials requires allowedDomains: credentials are injected by the proxy, which runs only when allowedDomains is set"
    else if invalidNames != [ ] then
      builtins.throw "${errorPrefix} injectedCredentials names must be env var names. Invalid: ${builtins.toJSON invalidNames}"
    else if invalidEntries != [ ] then
      builtins.throw "${errorPrefix} injectedCredentials entries must be { secret = <string>; placeholder = <string>; hosts = { \"<host>\" = { scheme = \"bearer\"; } | { scheme = \"basic\"; username = <string>; } | { scheme = \"header\"; header = <string>; }; }; }. Invalid: ${builtins.toJSON invalidEntries}"
    else if envClashes != [ ] then
      builtins.throw "${errorPrefix} injectedCredentials names must not also be set in env. Both: ${builtins.toJSON envClashes}"
    else if duplicateHosts != [ ] then
      builtins.throw "${errorPrefix} injectedCredentials must not name a host in more than one credential. Repeated: ${builtins.toJSON duplicateHosts}"
    else if unallowedHosts != [ ] then
      builtins.throw "${errorPrefix} injectedCredentials hosts must be allowed by allowedDomains. Not allowed: ${builtins.toJSON unallowedHosts}"
    else
      injectedCredentials;

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
      throwMsg = "${errorPrefix} Deprecated arguments:\n\n${throwMsgHints}";
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
in
{
  assertNoLegacyArgs = assertNoLegacyArgs;
  validateAllowedHostPorts = validateAllowedHostPorts;
  validatePublishedPorts = validatePublishedPorts;
  validateAllowUnixSockets = validateAllowUnixSockets;
  validateAllowHeadlessBrowsers = validateAllowHeadlessBrowsers;
  validateWorkspaceDir = validateWorkspaceDir;
  validateProxyRedirects = validateProxyRedirects;
  validateInjectedCredentials = validateInjectedCredentials;
}
