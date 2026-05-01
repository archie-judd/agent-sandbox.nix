{ pkgs }:
let
  sandboxProxy = import ./proxy { pkgs = pkgs; };
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
  # Shared by mkLinuxSandbox and mkDarwinSandbox. Starts the MITM proxy,
  # blocks until it reports its listening port via a FIFO, and creates
  # a combined CA bundle for the sandbox to trust the proxy's ephemeral CA.
  mkProxyStartupBashStr = allowlistFileStr: listenAddr: ''
    # Start the MITM proxy and read its port via FIFO
    _CA_CERT_FILE=$(mktemp /tmp/sandbox-ca-cert.XXXXXX)
    _PROXY_PORT_FIFO=$(mktemp -u /tmp/sandbox-proxy-port.XXXXXX)
    mkfifo "$_PROXY_PORT_FIFO"
    # Open FIFO read-write so neither side blocks waiting for the other
    exec 3<> "$_PROXY_PORT_FIFO"
    ${sandboxProxy}/bin/sandbox-proxy ${allowlistFileStr} "$_CA_CERT_FILE" ${listenAddr} > "$_PROXY_PORT_FIFO" 2>>/tmp/sandbox-proxy.log &
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
  /* mkLinuxSandbox — wraps a binary in a bubblewrap (bwrap) container.

       Bubblewrap creates a lightweight Linux namespace sandbox. It builds an
       entirely new mount tree from scratch — nothing is visible unless
       explicitly mounted in. The sandbox also unshares all namespaces (PID,
       user, IPC, UTS, cgroup) except network.

       ## Filesystem layout inside the sandbox

         Read-only bind mounts:
           /nix/store/<hash>-... — only the closure of allowedPackages
                     and pkg, not the entire nix store
           /etc/passwd   — user identity for programs that need it
           /etc/resolv.conf — DNS resolution
           /etc/ssl/certs   — TLS certificate verification
         Kernel filesystems:
           /proc   — mounted as a new procfs (only shows sandbox PIDs)
           /dev    — minimal devtmpfs (null, zero, urandom, etc.)
         Ephemeral tmpfs (empty, writable, lost on exit):
           /tmp    — scratch space
           $HOME   — prevents accidental reads of dotfiles; agent state
                      dirs are bind-mounted back on top of this
         Read-only bind mounts:
           $REPO_ROOT  — the git repo root, so git commands and reads of
                         files outside CWD work. CWD and GIT_DIR are
                         mounted rw on top of this.
         Read-write bind mounts:
           $CWD        — the project directory (always)
           stateDirs   — each path gets a --bind (e.g., ~/.config/claude)
           stateFiles  — each path gets a --bind (e.g., specific rc files)
           $GIT_DIR    — the .git dir, auto-detected. Needed when CWD is a
                         worktree and .git/common is outside CWD.
         Symlinks:
           /bin/sh -> bash — many scripts assume /bin/sh exists

       ## Key bwrap flags

         --unshare-all  Unshare every namespace type (mount, PID, user, IPC,
                        UTS, cgroup). The process is fully isolated.
         --share-net    Re-share the network namespace (undoes the network
                        part of --unshare-all). Required for API calls.
         --die-with-parent  Kill the sandbox if the parent shell exits, so
                            orphaned sandboxes don't accumulate.
         --setenv       Set environment variables inside the sandbox. PATH
                        is explicitly constructed from allowedPackages, so
                        only those binaries are callable.

       ## Debugging tips

         "No such file or directory":
           The binary is trying to access a path that isn't mounted.
           Run the wrapper with `strace -f -e trace=openat` to find the
           path, then add it to stateDirs/stateFiles.

         "Operation not permitted" on /proc or /dev:
           Unprivileged user namespaces may be disabled on the host.
           Check: sysctl kernel.unprivileged_userns_clone (needs to be 1).

         Git operations fail:
           If CWD is a git worktree, the real .git/common dir lives
           elsewhere. The wrapper auto-detects this with git rev-parse
           --git-common-dir, but it fails silently if git isn't available
           outside the sandbox. Check that $GIT_BIND is non-empty.

         DNS/TLS failures:
           Ensure /etc/resolv.conf and /etc/ssl/certs exist on the host.
           NixOS symlinks these — if the target is outside /etc, you may
           need to bind-mount the real paths.
  */
  mkLinuxSandbox = { pkg, binName, outName, allowedPackages, stateDirs ? [ ]
    , stateFiles ? [ ], extraEnv ? { }, restrictNetwork ? false
    , allowedDomains ? [ ] }:
    let
      implicitPackages = [ pkgs.cacert bashWrapper ];
      pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);
      mkDirsStr = builtins.concatStringsSep "\n"
        (map (dir: ''mkdir -p "${dir}"'') stateDirs);
      mkFilesStr = builtins.concatStringsSep "\n"
        (map (file: ''touch "${file}"'') stateFiles);
      bindDirsStr = builtins.concatStringsSep " "
        (map (dir: ''--bind "${dir}" "${dir}"'') stateDirs);
      # Adds each stateDir to the BOUND_PREFIXES shell array at runtime
      stateDirsBoundPrefixBashStr = builtins.concatStringsSep "\n"
        (map (dir: ''BOUND_PREFIXES+=("${dir}")'') stateDirs);

      symlinkHelpers = import ./lib/symlink-helpers.nix { inherit pkgs; };

      symlinkResolutionBashStr = ''
        # Complete the set of already-bound path prefixes
        ${stateDirsBoundPrefixBashStr}
        BOUND_PREFIXES+=("$CWD")
        BOUND_PREFIXES+=("/etc/resolv.conf" "/etc/passwd" "/etc/ssl/certs" "/etc/static" "/etc/pki")
        [[ -n "$REPO_ROOT" ]] && BOUND_PREFIXES+=("$REPO_ROOT")
        [[ -n "$GIT_DIR" ]] && BOUND_PREFIXES+=("$GIT_DIR")

        ${symlinkHelpers.isAlreadyBoundBashStr}
        ${symlinkHelpers.addSymlinkTargetBashStr}
        ${symlinkHelpers.followSymlinkChainBashStr}

        # Resolve stateFile symlinks — bind resolved targets, not the symlink paths
        STATE_FILE_BINDS=""
        ${builtins.concatStringsSep "\n"
        (map symlinkHelpers.mkResolveFileBashStr stateFiles)}

        # Scan stateDirs for internal symlinks and bind their resolved targets
        ${builtins.concatStringsSep "\n"
        (map symlinkHelpers.mkScanDirBashStr stateDirs)}
      '';

      extraEnvStr = builtins.concatStringsSep " "
        (map (name: "--setenv ${name} ${builtins.toJSON extraEnv.${name}}")
          (builtins.attrNames extraEnv));
      # Route-restriction script runs inside pasta's namespace (before bwrap).
      # Removes the default route and adds a host-only route so the namespace
      # can only reach the host machine (where the proxy listens), not the
      # wider internet.
      routeRestrictScript = pkgs.writeScript "sandbox-route-restrict" ''
        #!${pkgs.bashInteractive}/bin/bash
        set -euo pipefail
        IP="${pkgs.iproute2}/bin/ip"
        $IP route del default || { echo "FATAL: could not remove default route" >&2; exit 1; }
        $IP route add "$SANDBOX_HOST_IP"/32 via 10.0.2.2 || { echo "FATAL: could not add host route" >&2; exit 1; }
        exec "$@"
      '';
      conditionalNetworkingParams = if restrictNetwork then
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
          '' + mkProxyStartupBashStr allowlistFileStr "$_HOST_IP";
          bashTrapCleanupStr = ''
            trap 'kill $_PROXY_PID 2>/dev/null; rm -f "$_CA_CERT_FILE" "$_COMBINED_CA_BUNDLE"' EXIT'';
          sandboxExecBashStr = ''
            SANDBOX_HOST_IP="$_HOST_IP" ${pkgs.passt}/bin/pasta -4 --config-net -a 10.0.2.1 -g 10.0.2.2 -n 255.255.255.0 -- ${routeRestrictScript} '';
          etcResolvBind =
            "--ro-bind /dev/null /etc/resolv.conf"; # Block DNS resolution when restrictNetwork is true.
          sslCertEnvBubblewrapStr =
            ""; # CA cert env vars are set in caCertBubblewrapStr
        }
      else {
        warnIgnoredDomainsBashStr =
          if (hasAllowedDomains allowedDomains) then ''
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
      };

      # cacert and bashWrapper are always included: cacert so SSL/TLS
      # verification works, bashWrapper so the hardcoded SHELL and
      # /bin/sh symlink targets are always reachable in the store closure.
      # bashWrapper forces --norc --noprofile on every bash invocation so
      # that the sandboxed process cannot source /etc/bashrc or /etc/profile.
      closurePathsFile =
        pkgs.writeClosure (allowedPackages ++ implicitPackages ++ [ pkg ]);

      gitDetectionBashStr = ''
        GIT_BIND=""
        REPO_BIND=""
        if GIT_DIR=$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
          GIT_BIND="--bind $GIT_DIR $GIT_DIR"
          REPO_ROOT=$(dirname "$GIT_DIR")
          REPO_BIND="--ro-bind $REPO_ROOT $REPO_ROOT"
        fi
      '';

    in pkgs.writeTextFile {
      name = outName;
      executable = true;
      destination = "/bin/${outName}";
      text = ''
        #!${pkgs.bashInteractive}/bin/bash
        CWD=$(pwd)
        ${conditionalNetworkingParams.warnIgnoredDomainsBashStr}
        ${mkDirsStr}
        ${mkFilesStr}
        ${gitDetectionBashStr}

        # Build per-path ro-bind flags for the nix store closure
        CLOSURE_BINDS=""
        BOUND_PREFIXES=()
        while IFS= read -r storePath; do
          CLOSURE_BINDS="$CLOSURE_BINDS --ro-bind $storePath $storePath"
          BOUND_PREFIXES+=("$storePath")
        done < ${closurePathsFile}

        # Build arguments for nix files in the current working directory
        BWRAP_NIX_FILES=()
        for f in "$CWD"/*.nix; do
          [ -e "$f" ] && BWRAP_NIX_FILES+=(--bind /dev/null "$f")
        done

        ${symlinkResolutionBashStr}
        ${conditionalNetworkingParams.proxyStartupBashStr}
        ${conditionalNetworkingParams.bashTrapCleanupStr}
        ${conditionalNetworkingParams.sandboxExecBashStr}${pkgs.bubblewrap}/bin/bwrap \
          ${conditionalNetworkingParams.etcResolvBind} \
          --tmpfs /nix/store \
          $CLOSURE_BINDS \
          --ro-bind /etc/passwd /etc/passwd \
          --ro-bind-try /etc/ssl/certs /etc/ssl/certs \
          --ro-bind-try /etc/static /etc/static \
          --ro-bind-try /etc/pki /etc/pki \
          --proc /proc \
          --dev /dev \
          --tmpfs /tmp \
          --tmpfs "$HOME" \
          $REPO_BIND \
          --bind "$CWD" "$CWD" \
          --ro-bind / / \
          "''${BWRAP_NIX_FILES[@]}" \
          ${bindDirsStr} \
          $STATE_FILE_BINDS \
          $SYMLINK_PARENT_DIRS \
          $readonlyStateFileSymlinks \
          $readWriteStateFileSymlinks \
          $GIT_BIND \
          --symlink ${bashWrapper}/bin/bash /bin/sh \
          --unshare-all \
          --uid "$(id -u)" \
          --gid "$(id -g)" \
          --share-net \
          --die-with-parent \
          --chdir "$CWD" \
          --clearenv \
          --setenv HOME "$HOME" \
          --setenv TERM "$TERM" \
          --setenv SHELL "${bashWrapper}/bin/bash" \
          --setenv PATH "${pathStr}" \
          --setenv SSL_CERT_DIR "${pkgs.cacert}/etc/ssl/certs" \
          --setenv TMPDIR /tmp \
          ${conditionalNetworkingParams.sslCertEnvBubblewrapStr} \
          ${conditionalNetworkingParams.caCertBubblewrapStr} \
          ${conditionalNetworkingParams.proxyEnvBubblewrapStr} \
          ${extraEnvStr} \
          ${pkg}/bin/${binName} "$@"
      '';
    };
  /* mkDarwinSandbox — wraps a binary using macOS Seatbelt (sandbox-exec).

     Seatbelt uses a deny-default policy: everything is forbidden unless an
     explicit (allow ...) rule permits it. This is the inverse of bubblewrap's
     model (build an empty mount tree, then add things). Here the full
     filesystem is always visible to the kernel, but the sandbox blocks
     syscalls that access forbidden paths.

     The policy is a Scheme-like DSL compiled to a .sb file at Nix build
     time. Runtime values (CWD, HOME, GIT_DIR, etc.) are injected via
     sandbox-exec -D NAME=VALUE parameters and referenced as (param "NAME")
     in the profile.

     ## Policy structure (the .sb profile)

       (deny default)           — baseline: block everything
       (allow process-exec)     — allow exec() so the agent can run tools
       (allow process-fork)     — allow fork() for subprocesses
       (allow signal)           — allow sending/receiving signals
       (allow sysctl-read)      — allow reading kernel tuning values

       Mach IPC:
         Scoped to system services that most programs need. Each
         (allow mach-lookup (global-name ...)) opens one IPC channel.
         - com.apple.system.*           — core OS services
         - com.apple.SystemConfiguration.* — network config (SCDynamicStore)
         - com.apple.securityd.xpc      — Security framework (TLS, certs)
         - com.apple.SecurityServer      — keychain authorization
         - com.apple.trustd.agent        — certificate trust evaluation
         - com.apple.FSEvents            — filesystem event monitoring
         If the agent hangs or gets "bootstrap_look_up failed", a needed
         Mach service is probably missing from this list.

       Network:
         (allow network*) — fully open; no port/host restrictions.

       Device nodes & TTY:
         /dev/null, /dev/urandom, /dev/random, /dev/zero for reads.
         /dev/tty and /dev/ttysNNN for terminal I/O and ioctl (e.g.,
         querying terminal size). /dev/fd/* for file descriptor access.

       System libraries:
         /usr/lib, /usr/share, /System — Apple frameworks and dylibs.
         /Library/Preferences — system-wide plist defaults.
         These are read-only. Without them, almost nothing runs on macOS.

       Nix store:
         Only the closure of allowedPackages and pkg is readable/executable.
         Individual store paths are allowed via per-path rules generated at
         Nix build time (not the entire /nix tree).

       DNS / TLS / identity:
         /etc/resolv.conf (and /private/etc/resolv.conf — macOS uses
         /private/etc as the real location, with /etc as a symlink).
         /etc/ssl + /private/etc/ssl for certificate bundles.
         /etc/passwd + /private/etc/passwd for user identity lookups.

       Security framework (keychain & trust):
         /Library/Keychains — system keychain (root CA trust anchors).
         /private/var/db/mds — security framework metadata caches (the
         "MDS" directory). Without this, SecTrustEvaluate may fail with
         errSecInternalComponent, breaking all TLS connections.
         /private/var/run/systemkeychaincheck.done — signals keychain
         migration is complete.

       Temp directories:
         /tmp, /private/tmp, $TMPDIR, and /private/var/folders (which
         is where macOS actually puts per-user temp/cache dirs). All
         are read-write. TMPDIR is injected as a -D parameter.

       Ephemeral HOME:
         HOME is redirected to a temp directory under /tmp (covered by
         the existing /tmp subpath allow). This prevents subprocesses
         from reading or writing the real home directory. State paths
         that live under the real HOME are symlinked into the sandbox
         HOME so that $HOME-relative lookups resolve through to the
         real (Seatbelt-allowed) targets. The temp directory is cleaned
         up on exit via a trap. stateDirs and stateFiles are resolved
         to absolute paths before HOME is reassigned.

       Timezone:
         /private/var/db/timezone — so date/time formatting works.

       Filesystem traversal (stat on parent dirs):
         "/" gets file-read* (process startup requires readdir on root).
         All others — /var, /private, /private/var, /Users,
         $REAL_HOME, $REPO_ROOT_PARENT — get file-read-metadata only
         (literal paths, not subpath). This allows stat() for path
         component traversal without exposing directory contents via
         readdir(). Without at least metadata access, even reaching an
         allowed subpath can fail with EPERM during traversal.

       Working directory & repo:
         $CWD (subpath)        — full read-write to the project
         $REPO_ROOT (subpath)  — read-only; the repo root, which may
                                 differ from CWD if CWD is a subdirectory
         $GIT_DIR (subpath)    — the .git dir (may be outside repo root
                                 for worktrees)
         $GIT_CONFIG_DIR       — ~/.config/git (read-only) for user
                                 gitconfig, gitignore, etc.

       stateDirs / stateFiles:
         Each gets a (allow file-read* file-write* ...) rule. Dirs use
         (subpath ...) so all contents are accessible. Files use
         (literal ...) for exact-path access only.

     ## Debugging tips

       "Operation not permitted" / "denied by sandbox":
         macOS logs sandbox violations to the system log. Query them:
           log show --predicate 'eventMessage CONTAINS "deny"' --last 5m
         Each entry shows the denied operation and path, telling you
         exactly which (allow ...) rule is missing.

       TLS / HTTPS failures ("SecureTransport" or "errSecInternalComponent"):
         Usually means a Mach service or keychain path is blocked:
         - Check that com.apple.securityd.xpc and com.apple.trustd.agent
           are in the mach-lookup allows.
         - Check that /Library/Keychains and /private/var/db/mds are
           readable.

       "sandbox-exec: ... (os/kern) invalid argument":
         Syntax error in the .sb profile. Inspect the built file:
           cat /nix/store/...-<outName>-sandbox.sb
         Common causes: unmatched parens, bad regex syntax, or a
         (param "X") with no corresponding -D X=value flag.

       Agent can't find tools / PATH is empty:
         PATH is set to the Nix-built basePath from allowedPackages.
         It is NOT inherited from the parent shell. If a tool is missing,
         add its package to allowedPackages.

       Git operations fail:
         GIT_DIR is auto-detected via git rev-parse. If you're outside
         a repo, it falls back to /nonexistent-git-dir (a harmless dummy
         that satisfies the (param "GIT_DIR") reference without granting
         access to anything real).

       NOTE: sandbox-exec is deprecated by Apple and may be removed in a
       future macOS release. It still works as of macOS 15 (Sequoia) but
       produces no deprecation warnings at runtime — only the man page
       mentions it. There is no supported replacement for unprivileged
       sandboxing on macOS.
  */
  mkDarwinSandbox = { pkg, binName, outName, allowedPackages, stateDirs ? [ ]
    , stateFiles ? [ ], extraEnv ? { }, restrictNetwork ? false
    , allowedDomains ? [ ] }:
    let
      implicitPackages = [ pkgs.cacert bashWrapper ];
      pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);

      # Generate indexed param names
      stateDirParams = builtins.genList (i: {
        name = "STATE_DIR_${toString i}";
        path = builtins.elemAt stateDirs i;
      }) (builtins.length stateDirs);

      stateFileParams = builtins.genList (i: {
        name = "STATE_FILE_${toString i}";
        path = builtins.elemAt stateFiles i;
      }) (builtins.length stateFiles);

      # For the .sb file
      seatbeltAllowReadWriteExec = builtins.concatStringsSep "\n" (map (p: ''
        (allow file-read* file-write* (subpath (param "${p.name}")))
        (allow process-exec (subpath (param "${p.name}")))'') stateDirParams);

      seatbeltAllowFiles = builtins.concatStringsSep "\n" (map
        (p: ''(allow file-read* file-write* (literal (param "${p.name}")))'')
        stateFileParams);

      # For the wrapper's sandbox-exec invocation — use resolved shell vars
      stateDirFlags = builtins.concatStringsSep " \\\n  "
        (map (p: ''-D ${p.name}="$_RESOLVED_${p.name}"'') stateDirParams);

      stateFileFlags = builtins.concatStringsSep " \\\n  "
        (map (p: ''-D ${p.name}="$_RESOLVED_${p.name}"'') stateFileParams);

      # Resolve stateDirs/stateFiles while HOME is still real
      resolveStateDirsStr = builtins.concatStringsSep "\n"
        (map (p: ''_RESOLVED_${p.name}="${p.path}"'') stateDirParams);

      resolveStateFilesStr = builtins.concatStringsSep "\n"
        (map (p: ''_RESOLVED_${p.name}="${p.path}"'') stateFileParams);

      # Symlink resolved state paths into the sandbox HOME so that
      # $HOME-relative lookups land on the real paths. Only creates
      # symlinks for paths that actually live under the real HOME.
      mkSymlinkHomeMappingStr = params:
        builtins.concatStringsSep "\n" (map (p: ''
          if [[ "$_RESOLVED_${p.name}" == "$REAL_HOME"/* ]]; then
            _REL="''${_RESOLVED_${p.name}#$REAL_HOME/}"
            mkdir -p "$SANDBOX_HOME/$(dirname "$_REL")"
            ln -sfn "$_RESOLVED_${p.name}" "$SANDBOX_HOME/$_REL"
          fi'') params);

      symlinkStateDirsStr = mkSymlinkHomeMappingStr stateDirParams;
      symlinkStateFilesStr = mkSymlinkHomeMappingStr stateFileParams;

      mkDirsStr = builtins.concatStringsSep "\n"
        (map (dir: ''mkdir -p "${dir}"'') stateDirs);
      mkFilesStr = builtins.concatStringsSep "\n"
        (map (file: ''touch "${file}"'') stateFiles);

      extraEnvInlineStr = builtins.concatStringsSep " \\\n        "
        (map (name: "${name}=${builtins.toJSON extraEnv.${name}}")
          (builtins.attrNames extraEnv));

      conditionalNetworkingParams = if restrictNetwork then
        let allowlistFileStr = mkAllowlistFile allowedDomains;
        in {
          warnIgnoredDomainsBashStr = "";
          proxyEnvInlineBashStr = ''
            HTTP_PROXY="http://127.0.0.1:$_PROXY_PORT" HTTPS_PROXY="http://127.0.0.1:$_PROXY_PORT" http_proxy="http://127.0.0.1:$_PROXY_PORT" https_proxy="http://127.0.0.1:$_PROXY_PORT"'';
          caCertEnvInlineBashStr = ''
            SSL_CERT_FILE="$_COMBINED_CA_BUNDLE" NIX_SSL_CERT_FILE="$_COMBINED_CA_BUNDLE" NODE_EXTRA_CA_CERTS="$_CA_CERT_FILE" REQUESTS_CA_BUNDLE="$_COMBINED_CA_BUNDLE"'';
          networkSeatbeltRulesStr = ''
            ;; Network — restricted to localhost only (proxy-based domain filtering)
            (allow network-outbound (remote ip "localhost:*"))
            (allow network-outbound (remote unix-socket))
            (allow network-bind (local ip "localhost:*"))
            (allow system-socket)
          '';
          proxyStartupBashStr =
            mkProxyStartupBashStr allowlistFileStr "127.0.0.1";
          bashTrapCleanupStr = ''
            trap 'kill $_PROXY_PID 2>/dev/null; rm -f "$_CA_CERT_FILE" "$_COMBINED_CA_BUNDLE"; rm -rf "$SANDBOX_HOME" "$SANDBOX_PROFILE"' EXIT'';
          sandboxExecBashStr = "";

        }
      else {
        warnIgnoredDomainsBashStr =
          if (hasAllowedDomains allowedDomains) then ''
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
        bashTrapCleanupStr = ''trap 'rm -rf "$SANDBOX_HOME" "$SANDBOX_PROFILE"' EXIT'';
        sandboxExecBashStr = "exec ";

      };

      # cacert and bashWrapper are always included: cacert so SSL/TLS
      # verification works, bashWrapper so the hardcoded SHELL target
      # is always reachable in the store closure. bashWrapper forces
      # --norc --noprofile on every bash invocation so that the sandboxed
      # process cannot source /etc/bashrc or /etc/profile.
      closurePathsFile =
        pkgs.writeClosure (allowedPackages ++ implicitPackages ++ [ pkg ]);

      gitDetectionBashStr = ''
        if GIT_DIR=$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
            GIT_DIR_PARAM="$GIT_DIR"
            REPO_ROOT=$(dirname "$GIT_DIR_PARAM")
            REPO_ROOT_PARENT=$(dirname "$REPO_ROOT")
        else
            GIT_DIR_PARAM="/nonexistent-git-dir"
            REPO_ROOT="/nonexistent-repo-root"
            REPO_ROOT_PARENT="/nonexistent-repo-root"
        fi
      '';

      # Walk from REPO_ROOT (or CWD if no git repo) up to REAL_HOME,
      # collecting intermediate directories that need file-read-metadata
      # for path resolution (realpathSync, lstat, etc.).
      ancestorTraversalBashStr = ''
        _WALK_FROM="$REPO_ROOT"
        if [ "$_WALK_FROM" = "/nonexistent-repo-root" ]; then
          _WALK_FROM="$CWD"
        fi
        ANCESTOR_DIRS=()
        _CURRENT=$(dirname "$_WALK_FROM")
        while [ "$_CURRENT" != "$REAL_HOME" ] && [ "$_CURRENT" != "/" ]; do
          ANCESTOR_DIRS+=("$_CURRENT")
          _CURRENT=$(dirname "$_CURRENT")
        done
      '';

      # Copy the static seatbelt profile to a temp file and append
      # file-read-metadata rules for each ancestor directory at runtime.
      ancestorProfilePatchBashStr = ''
        SANDBOX_PROFILE=$(mktemp /tmp/sandbox-profile-XXXXXX)
        cp ${seatbeltProfile} "$SANDBOX_PROFILE"
        for _dir in "''${ANCESTOR_DIRS[@]}"; do
          printf '    (allow file-read-metadata (literal "%s"))\n' "$_dir" >> "$SANDBOX_PROFILE"
        done
      '';
      seatbeltStaticRules = import ./lib/seatbelt-profile.nix {
        networkRulesStr = conditionalNetworkingParams.networkSeatbeltRulesStr;
        allowReadWriteExecStr = seatbeltAllowReadWriteExec;
        allowFilesStr = seatbeltAllowFiles;
      };

      seatbeltProfile = pkgs.runCommand "${outName}-sandbox.sb" {
        closurePaths = closurePathsFile;
        staticRules = seatbeltStaticRules;
      } ''
        {
          echo "$staticRules"

          echo ""
          echo "    ;; Nix store — only closure of allowed packages"

          while IFS= read -r storePath; do
            echo "    (allow file-read* (subpath \"$storePath\"))"
            echo "    (allow process-exec (subpath \"$storePath\"))"
          done < "$closurePaths"
        } > $out
      '';

    in pkgs.writeTextFile {
      name = outName;
      executable = true;
      destination = "/bin/${outName}";
      text = ''
        #!${pkgs.bashInteractive}/bin/bash
        CWD=$(pwd)
        ${conditionalNetworkingParams.warnIgnoredDomainsBashStr}

        # Ensure stateDirs/stateFiles exist while HOME still points at real home
        ${mkDirsStr}
        ${mkFilesStr}

        ${gitDetectionBashStr}

        # Capture real HOME paths before redirecting
        GIT_CONFIG_DIR="$HOME/.config/git"

        # Resolve stateDirs/stateFiles paths while $HOME still points at real home
        ${resolveStateDirsStr}
        ${resolveStateFilesStr}

        # Create an ephemeral HOME so subprocesses don't touch the real home.
        # Lives under /tmp which is already allowed read-write in the profile.
        REAL_HOME="$HOME"
        SANDBOX_HOME=$(mktemp -d /private/tmp/sandbox-home.XXXXXX)

        # Symlink state dirs/files into sandbox HOME so $HOME-relative lookups
        # reach the real paths through the Seatbelt-allowed targets.
        ${symlinkStateDirsStr}
        ${symlinkStateFilesStr}

        # Walk ancestor directories between REAL_HOME and REPO_ROOT (or CWD)
        # and patch the seatbelt profile at runtime with file-read-metadata rules.
        ${ancestorTraversalBashStr}
        ${ancestorProfilePatchBashStr}

        ${conditionalNetworkingParams.proxyStartupBashStr}
        ${conditionalNetworkingParams.bashTrapCleanupStr}


        ${conditionalNetworkingParams.sandboxExecBashStr}/usr/bin/env -i \
          HOME="$SANDBOX_HOME" \
          TERM="$TERM" \
          SHELL="${bashWrapper}/bin/bash" \
          PATH="${pathStr}" \
          SSL_CERT_DIR="${pkgs.cacert}/etc/ssl/certs" \
          GIT_CONFIG_DIR="$GIT_CONFIG_DIR" \
          TMPDIR=/tmp \
          ${conditionalNetworkingParams.caCertEnvInlineBashStr} \
          ${conditionalNetworkingParams.proxyEnvInlineBashStr} \
          ${extraEnvInlineStr} \
          /usr/bin/sandbox-exec \
          -f "$SANDBOX_PROFILE" \
          -D CWD="$CWD" \
          -D GIT_DIR="$GIT_DIR_PARAM" \
          -D REPO_ROOT="$REPO_ROOT" \
          -D REPO_ROOT_PARENT="$REPO_ROOT_PARENT" \
          -D GIT_CONFIG_DIR="$GIT_CONFIG_DIR" \
          -D TMPDIR="/tmp" \
          -D HOME="$SANDBOX_HOME"  \
          -D REAL_HOME="$REAL_HOME" \
          -D HOME_CACHE="$SANDBOX_HOME/.cache" \
          -D HOME_LOCAL="$SANDBOX_HOME/.local" \
          -D HOME_LOCAL_STATE="$SANDBOX_HOME/.local/state" \
          -D HOME_LOCAL_SHARE="$SANDBOX_HOME/.local/share" ${stateDirFlags} ${stateFileFlags} \
          ${pkg}/bin/${binName} "$@"
      '';
    };

in {
  mkSandbox = if pkgs.stdenv.isDarwin then mkDarwinSandbox else mkLinuxSandbox;
}

