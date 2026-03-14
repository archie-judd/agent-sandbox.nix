{ pkgs }:
let
  sandboxProxy = import ./proxy { pkgs = pkgs; };
  /* mkLinuxSandbox — wraps a binary in a bubblewrap (bwrap) container.

       Bubblewrap creates a lightweight Linux namespace sandbox. It builds an
       entirely new mount tree from scratch — nothing is visible unless
       explicitly mounted in. The sandbox also unshares all namespaces (PID,
       user, IPC, UTS, cgroup) except network.

       ## Filesystem layout inside the sandbox

         Read-only bind mounts:
           /nix    — so the wrapped binary and its deps are available
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
         Read-write bind mounts:
           $CWD        — the project directory (always)
           stateDirs   — each path gets a --bind (e.g., ~/.config/claude)
           stateFiles  — each path gets a --bind (e.g., specific rc files)
           $GIT_DIR    — the .git dir, auto-detected; only if inside a repo.
                         Needed when CWD is a worktree and .git/common is
                         outside CWD.
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
      pathStr = pkgs.lib.makeBinPath allowedPackages;
      mkDirsStr = builtins.concatStringsSep "\n"
        (map (dir: ''mkdir -p "${dir}"'') stateDirs);
      mkFilesStr = builtins.concatStringsSep "\n"
        (map (file: ''touch "${file}"'') stateFiles);
      bindDirsStr = builtins.concatStringsSep " "
        (map (dir: ''--bind "${dir}" "${dir}"'') stateDirs);
      bindFilesStr = builtins.concatStringsSep " "
        (map (file: ''--bind "${file}" "${file}"'') stateFiles);
      extraEnvStr = builtins.concatStringsSep " "
        (map (name: "--setenv ${name} ${builtins.toJSON extraEnv.${name}}")
          (builtins.attrNames extraEnv));
      conditionalNetworkingParams = if restrictNetwork then
        let
          allowlistFileStr = pkgs.writeText "sandbox-allowlist"
            (builtins.concatStringsSep "\n" allowedDomains + "\n");
        in {
          warnIgnoredDomainsBashStr = "";
          proxyEnvBubblewrapStr = ''
            --setenv HTTP_PROXY "http://127.0.0.1:$_PROXY_PORT" --setenv HTTPS_PROXY "http://127.0.0.1:$_PROXY_PORT" --setenv http_proxy "http://127.0.0.1:$_PROXY_PORT" --setenv https_proxy "http://127.0.0.1:$_PROXY_PORT"'';
          proxyStartupBashStr = ''
            # Start the domain-filtering proxy and read its port via FIFO
            _PROXY_PORT_FIFO=$(mktemp -u /tmp/sandbox-proxy-port.XXXXXX)
            mkfifo "$_PROXY_PORT_FIFO"
            # Open FIFO read-write so neither side blocks waiting for the other
            exec 3<> "$_PROXY_PORT_FIFO"
            ${sandboxProxy}/bin/sandbox-proxy ${allowlistFileStr} > "$_PROXY_PORT_FIFO" 2>>/tmp/sandbox-proxy.log &
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
          '';
          bashTrapCleanupStr = "trap 'kill $_PROXY_PID 2>/dev/null' EXIT";
          sandboxExecBashStr = "";
        }
      else {
        warnIgnoredDomainsBashStr = if (allowedDomains != [ ]) then ''
          echo "WARNING: allowedDomains is set but restrictNetwork is false — domains will be ignored" >&2
        '' else
          "";
        proxyEnvBubblewrapStr = "";
        proxyStartupBashStr = "";
        bashTrapCleanupStr = "";
        sandboxExecBashStr = "exec ";

      };

    in pkgs.writeShellScriptBin outName ''
      CWD=$(pwd)
      ${conditionalNetworkingParams.warnIgnoredDomainsBashStr}
      ${mkDirsStr}
      ${mkFilesStr}
      GIT_BIND=""
      if GIT_DIR=$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        GIT_BIND="--bind $GIT_DIR $GIT_DIR"
      fi
      ${conditionalNetworkingParams.proxyStartupBashStr}
      ${conditionalNetworkingParams.bashTrapCleanupStr}
      ${conditionalNetworkingParams.sandboxExecBashStr}${pkgs.bubblewrap}/bin/bwrap \
        --ro-bind /nix /nix \
        --ro-bind /etc/passwd /etc/passwd \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/ssl/certs /etc/ssl/certs \
        --ro-bind-try /etc/static /etc/static \
        --ro-bind-try /etc/pki /etc/pki \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs "$HOME" \
        --bind "$CWD" "$CWD" \
        ${bindDirsStr} \
        ${bindFilesStr} \
        $GIT_BIND \
        --symlink ${pkgs.bash}/bin/bash /bin/sh \
        --unshare-all \
        --share-net \
        --die-with-parent \
        --chdir "$CWD" \
        --clearenv \
        --setenv HOME "$HOME" \
        --setenv TERM "$TERM" \
        --setenv SHELL "${pkgs.bash}/bin/bash" \
        --setenv PATH "${pathStr}" \
        --setenv SSL_CERT_FILE "''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
        --setenv SSL_CERT_DIR "''${SSL_CERT_DIR:-/etc/ssl/certs}" \
        --setenv NIX_SSL_CERT_FILE "''${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
        --setenv TMPDIR /tmp \
        ${conditionalNetworkingParams.proxyEnvBubblewrapStr} \
        ${extraEnvStr} \
        ${pkg}/bin/${binName} "$@"
    '';
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
         /nix — read-only. All packages and their dependencies live here.

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
         Allows stat() on /, /var, /private, /private/var, /Users,
         $HOME, and $REPO_ROOT_PARENT. These are
         read-only and restricted to literal paths (not subpath).
         Needed because path resolution walks each component — without
         this, even accessing an allowed subpath can fail with EPERM
         during the stat() of a parent directory.

       Working directory & repo:
         $CWD (subpath)        — full read-write to the project
         $REPO_ROOT (subpath)  — the repo root, which may differ from
                                 CWD if CWD is a subdirectory
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
      pathStr = pkgs.lib.makeBinPath allowedPackages;
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
      symlinkStateDirsStr = builtins.concatStringsSep "\n" (map (p: ''
        if [[ "$_RESOLVED_${p.name}" == "$REAL_HOME"/* ]]; then
          _REL="''${_RESOLVED_${p.name}#$REAL_HOME/}"
          mkdir -p "$SANDBOX_HOME/$(dirname "$_REL")"
          ln -sfn "$_RESOLVED_${p.name}" "$SANDBOX_HOME/$_REL"
        fi'') stateDirParams);

      symlinkStateFilesStr = builtins.concatStringsSep "\n" (map (p: ''
        if [[ "$_RESOLVED_${p.name}" == "$REAL_HOME"/* ]]; then
          _REL="''${_RESOLVED_${p.name}#$REAL_HOME/}"
          mkdir -p "$SANDBOX_HOME/$(dirname "$_REL")"
          ln -sfn "$_RESOLVED_${p.name}" "$SANDBOX_HOME/$_REL"
        fi'') stateFileParams);

      mkDirsStr = builtins.concatStringsSep "\n"
        (map (dir: ''mkdir -p "${dir}"'') stateDirs);
      mkFilesStr = builtins.concatStringsSep "\n"
        (map (file: ''touch "${file}"'') stateFiles);

      extraEnvInlineStr = builtins.concatStringsSep " \\\n        "
        (map (name: "${name}=${builtins.toJSON extraEnv.${name}}")
          (builtins.attrNames extraEnv));

      conditionalNetworkingParams = if restrictNetwork then
        let
          allowlistFileStr = pkgs.writeText "sandbox-allowlist"
            (builtins.concatStringsSep "\n" allowedDomains + "\n");
        in {
          warnIgnoredDomainsBashStr = "";
          proxyEnvInlineBashStr = ''
            HTTP_PROXY="http://127.0.0.1:$_PROXY_PORT" HTTPS_PROXY="http://127.0.0.1:$_PROXY_PORT" http_proxy="http://127.0.0.1:$_PROXY_PORT" https_proxy="http://127.0.0.1:$_PROXY_PORT"'';
          networkSeatbeltRulesStr = ''
            ;; Network — restricted to localhost only (proxy-based domain filtering)
            (allow network-outbound (remote ip "localhost:*"))
            (allow network-outbound (remote unix-socket))
            (allow network-bind (local ip "localhost:*"))
            (allow system-socket)
          '';
          proxyStartupBashStr = ''
            # Start the domain-filtering proxy and read its port via FIFO
            _PROXY_PORT_FIFO=$(mktemp -u /tmp/sandbox-proxy-port.XXXXXX)
            mkfifo "$_PROXY_PORT_FIFO"
            # Open FIFO read-write so neither side blocks waiting for the other
            exec 3<> "$_PROXY_PORT_FIFO"
            ${sandboxProxy}/bin/sandbox-proxy ${allowlistFileStr} > "$_PROXY_PORT_FIFO" 2>>/tmp/sandbox-proxy.log &
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
          '';
          bashTrapCleanupStr = ''
            trap 'kill $_PROXY_PID 2>/dev/null; rm -rf "$SANDBOX_HOME"' EXIT'';
          sandboxExecBashStr = "";

        }
      else {
        warnIgnoredDomainsBashStr = if allowedDomains != [ ] then ''
          echo "WARNING: allowedDomains is set but restrictNetwork is false — domains will be ignored" >&2
        '' else
          "";
        proxyEnvInlineBashStr = "";
        networkSeatbeltRulesStr = ''
          ;; Network
          (allow network*)
          (allow system-socket)
        '';
        proxyStartupBashStr = "";
        bashTrapCleanupStr = ''trap 'rm -rf "$SANDBOX_HOME"' EXIT'';
        sandboxExecBashStr = "exec ";

      };

      seatbeltProfile = pkgs.writeText "${outName}-sandbox.sb" ''
        (version 1)
        (deny default)

        ;; Process control
        (allow process-fork)
        (allow signal)
        (allow sysctl-read)

        ;; Process execution
        (allow process-exec (subpath "/nix"))
        (allow process-exec (subpath (param "CWD")))
        (allow process-exec (literal "/bin/sh"))
        (allow process-exec (literal "/bin/bash"))
        (allow process-exec (literal "/usr/bin/env"))
        (allow process-exec (literal "/usr/bin/plutil"))

        ;; Mach IPC — scoped to system services, security framework, FSEvents
        (allow mach-lookup (global-name-prefix "com.apple.system."))
        (allow mach-lookup (global-name-prefix "com.apple.SystemConfiguration."))
        (allow mach-lookup (global-name "com.apple.securityd.xpc"))
        (allow mach-lookup (global-name "com.apple.SecurityServer"))
        (allow mach-lookup (global-name "com.apple.trustd.agent"))
        (allow mach-lookup (global-name "com.apple.FSEvents"))
        (allow mach-lookup (global-name "com.apple.diagnosticd"))
        (allow mach-register)
        (allow ipc-posix-shm-read-data)
        (allow ipc-posix-shm-write-data)
        (allow ipc-posix-shm-write-create)

        ${conditionalNetworkingParams.networkSeatbeltRulesStr}

        ;; Device nodes & terminal I/O
        (allow file-read*
          (literal "/dev/null")
          (literal "/dev/urandom")
          (literal "/dev/random")
          (literal "/dev/zero")
          (literal "/dev/ptmx")
          (literal "/private/var/select/sh"))
        (allow file-write* (literal "/dev/null"))
        (allow file-read* file-write*
          (literal "/dev/tty")
          (literal "/dev/ptmx")
          (regex #"^/dev/fd/")
          (regex #"^/dev/ttys[0-9]")
          (regex #"^/dev/pty")
          (regex #"^/dev/ttyp"))
        (allow file-ioctl
          (literal "/dev/tty")
          (literal "/dev/ptmx")
          (regex #"^/dev/ttys[0-9]")
          (regex #"^/dev/pty")
          (regex #"^/dev/ttyp"))
        (allow file-read-metadata
          (literal "/dev/stdout")
          (literal "/dev/stderr")
          (literal "/dev/stdin")
          (regex #"^/dev/ttyq")
          (regex #"^/dev/ttyr")
          (literal "/dev/dtracehelper"))

        ;; System libraries & frameworks
        (allow file-read*
          (subpath "/usr/lib")
          (subpath "/usr/bin")
          (subpath "/usr/share")
          (subpath "/bin")
          (subpath "/System")
          (subpath "/Library/Preferences"))

        ;; Nix store (read-only)
        (allow file-read* (subpath "/nix"))

        ;; DNS, TLS & name resolution
        (allow file-read*
          (literal "/private/etc/resolv.conf")
          (literal "/private/var/run/resolv.conf")
          (subpath "/private/etc/ssl")
          (literal "/private/etc/passwd")
          (literal "/private/etc/localtime")
          (literal "/private/etc/profile")
          (literal "/private/etc/bashrc")
          (subpath "/private/etc/static")
          (literal "/private/etc/hosts"))

        ;; Security framework — system keychains & trust databases
        (allow file-read* 
          (subpath "/private/var/db/mds")
          (subpath "/Library/Keychains")
          (literal "/private/var/run/systemkeychaincheck.done"))

        ;; Temp directories
        (allow file-read* file-write*
          (subpath "/tmp")
          (subpath "/private/tmp")
          (subpath (param "TMPDIR"))
          (subpath "/private/var/folders"))

        ;; Filesystem traversal — stat() on parent dirs for path resolution
        (allow file-read*
          (literal "/")
          (literal "/var")
          (literal "/dev")
          (literal "/private")
          (literal "/private/var")
          (literal "/etc")
          (literal "/private/etc")
          (literal "/private/var/db")
          (literal "/Users")
          (literal (param "HOME"))
          (subpath (param "HOME"))
          (literal (param "REAL_HOME"))
          (subpath (param "REAL_HOME"))
          (literal (param "HOME_LOCAL"))
          (literal (param "HOME_CACHE"))
          (literal (param "HOME_LOCAL_SHARE"))
          (literal (param "HOME_LOCAL_STATE"))
          (literal (param "REPO_ROOT_PARENT")))

        ;; Working directory & repository
        (allow file-read* file-write* (subpath (param "CWD")))
        (allow file-read* file-write* (subpath (param "REPO_ROOT")))
        (allow file-read* file-write* (subpath (param "GIT_DIR")))
        (allow file-read* (subpath (param "GIT_CONFIG_DIR")))

        ;; Timezone
        (allow file-read* (subpath "/private/var/db/timezone"))

        ;; Explicit state directories & files
        ${seatbeltAllowReadWriteExec}
        ${seatbeltAllowFiles};
      '';

    in pkgs.writeShellScriptBin outName ''
      CWD=$(pwd)
      ${conditionalNetworkingParams.warnIgnoredDomainsBashStr}

      # Ensure stateDirs/stateFiles exist while HOME still points at real home
      ${mkDirsStr}
      ${mkFilesStr}

      if GIT_DIR=$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
          GIT_DIR_PARAM="$GIT_DIR"
          REPO_ROOT=$(dirname "$GIT_DIR_PARAM")
          REPO_ROOT_PARENT=$(dirname "$REPO_ROOT")
      else
          GIT_DIR_PARAM="/nonexistent-git-dir"
          REPO_ROOT="/nonexistent-repo-root"
          REPO_ROOT_PARENT="/nonexistent-repo-root"
      fi

      # Capture real HOME paths before redirecting
      GIT_CONFIG_DIR="$HOME/.config/git"

      # Resolve stateDirs/stateFiles paths while $HOME still points at real home
      ${resolveStateDirsStr}
      ${resolveStateFilesStr}

      # Create an ephemeral HOME so subprocesses don't touch the real home.
      # Lives under /tmp which is already allowed read-write in the profile.
      REAL_HOME="$HOME"
      SANDBOX_HOME=$(mktemp -d /tmp/sandbox-home.XXXXXX)

      # Symlink state dirs/files into sandbox HOME so $HOME-relative lookups
      # reach the real paths through the Seatbelt-allowed targets.
      ${symlinkStateDirsStr}
      ${symlinkStateFilesStr}

      ${conditionalNetworkingParams.proxyStartupBashStr}
      ${conditionalNetworkingParams.bashTrapCleanupStr}


      ${conditionalNetworkingParams.sandboxExecBashStr}/usr/bin/env -i \
        HOME="$SANDBOX_HOME" \
        TERM="$TERM" \
        SHELL="${pkgs.bash}/bin/bash" \
        PATH="${pathStr}" \
        SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
        SSL_CERT_DIR="''${SSL_CERT_DIR:-/etc/ssl/certs}" \
        GIT_CONFIG_DIR="$GIT_CONFIG_DIR" \
        TMPDIR=/tmp \
        ${conditionalNetworkingParams.proxyEnvInlineBashStr} \
        ${extraEnvInlineStr} \
        /usr/bin/sandbox-exec \
        -f ${seatbeltProfile} \
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

in {
  mkSandbox = if pkgs.stdenv.isDarwin then mkDarwinSandbox else mkLinuxSandbox;
}

