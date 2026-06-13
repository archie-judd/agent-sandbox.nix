/*
  mkLinuxSandbox — wraps a binary in a bubblewrap (bwrap) container.

    Bubblewrap creates a lightweight Linux namespace sandbox. It builds an
    entirely new mount tree from scratch — nothing is visible unless
    explicitly mounted in. The sandbox also unshares all namespaces (PID,
    user, IPC, UTS, cgroup) except network.

    ## Filesystem layout inside the sandbox

      Read-only bind mounts:
        /nix/store/<hash>-... — only the closure of allowedPackages
                  and pkg, not the entire nix store
        /etc/passwd   — user identity for programs that need it
        /etc/hosts    — loopback name resolution (localhost → 127.0.0.1)
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
        rwDirs      — each path gets a --bind (e.g., ~/.config/claude)
        rwFiles     — each path gets a --bind (e.g., specific rc files)
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
        path, then add it to rwDirs/rwFiles.

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
{ pkgs, shared }:
{
  pkg,
  binName,
  outName,
  allowedPackages,
  rwDirs ? [ ],
  rwFiles ? [ ],
  env ? { },
  allowedDomains ? null,
  # Internal: maps "host" → "addr:port" so the proxy dials the local address
  # for those hosts instead of resolving the original. Used by the test
  # harness to point fake domains at a local httpbin. Not part of the
  # public API — leading underscore signals internal-only.
  _proxyRedirects ? { },
  # Legacy args that should not be used in new code. Still accepted for
  # backward compatibility, but will throw an error if used with
  # assertNoLegacyArgs.
  restrictNetwork ? null,
  extraEnv ? null,
  stateDirs ? null,
  stateFiles ? null,
}:
let
  bashWrapper = shared.bashWrapper;
  # Runs inside the sandbox ahead of the agent binary: probes for a declared
  # git identity and warns the user at launch if none is found, then exec's
  # the real command. See lib/pre-entry-script.sh.
  preEntryScript = pkgs.writeShellScript "pre-entry-script" (builtins.readFile ../pre-entry-script.sh);
  emptyFile = pkgs.writeText "sandbox-empty" "";
  implicitPackages = [
    pkgs.cacert
    bashWrapper
  ];
  hostsFile = pkgs.writeText "sandbox-hosts" ''
    127.0.0.1 localhost
    ::1       localhost
  '';
  pathStr = pkgs.lib.makeBinPath (allowedPackages ++ implicitPackages);
  mkDirsStr = builtins.concatStringsSep "\n" (map (dir: ''mkdir -p "${dir}"'') rwDirs);
  mkFilesStr = builtins.concatStringsSep "\n" (map (file: ''touch "${file}"'') rwFiles);
  bindDirsStr = builtins.concatStringsSep " " (map (dir: ''--bind "${dir}" "${dir}"'') rwDirs);
  # Adds each rwDir to the BOUND_PREFIXES shell array at runtime
  stateDirsBoundPrefixBashStr = builtins.concatStringsSep "\n" (
    map (dir: ''BOUND_PREFIXES+=("${dir}")'') rwDirs
  );

  symlinkHelpers = import ./symlink-helpers.nix {
    pkgs = pkgs;
    shared = shared;
  };

  symlinkResolutionBashStr =
    # bash
    ''
      # Complete the set of already-bound path prefixes
      ${stateDirsBoundPrefixBashStr}
      BOUND_PREFIXES+=("$CWD")
      BOUND_PREFIXES+=("/etc/resolv.conf" "/etc/passwd" "/etc/ssl/certs" "/etc/static" "/etc/pki")
      [[ -n "$REPO_ROOT" ]] && BOUND_PREFIXES+=("$REPO_ROOT")
      [[ -n "$GIT_DIR" ]] && BOUND_PREFIXES+=("$GIT_DIR")

      ${symlinkHelpers.isAlreadyBoundBashStr}
      ${symlinkHelpers.addSymlinkTargetBashStr}
      ${symlinkHelpers.followSymlinkChainBashStr}

      # Resolve rwFile symlinks — bind resolved targets, not the symlink paths
      STATE_FILE_BINDS=""
      ${builtins.concatStringsSep "\n" (map symlinkHelpers.mkResolveFileBashStr rwFiles)}

      # Scan rwDirs for internal symlinks and bind their resolved targets
      ${builtins.concatStringsSep "\n" (map symlinkHelpers.mkScanDirBashStr rwDirs)}
    '';

  extraEnvStr = builtins.concatStringsSep " " (
    map (name: "--setenv ${name} ${builtins.toJSON env.${name}}") (builtins.attrNames env)
  );

  conditionalNetworkingParams = import ./networking.nix {
    pkgs = pkgs;
    shared = shared;
    restrictNetwork = allowedDomains != null;
    allowedDomains = if allowedDomains != null then allowedDomains else [ ];
    _proxyRedirects = _proxyRedirects;
  };

  sandboxPasswdBashStr =
    # bash
    ''
      _SANDBOX_PASSWD=$(mktemp /tmp/sandbox-passwd.XXXXXX)
      printf 'user:x:%s:%s:sandbox user:%s:/bin/sh\n' "$(id -u)" "$(id -g)" "$HOME" > "$_SANDBOX_PASSWD"
    '';

  trapBashStr =
    let
      networkCmds = conditionalNetworkingParams.bashCleanupCommandsStr;
      cmds =
        if networkCmds == "" then
          # bash
          ''
            rm -f "$_SANDBOX_PASSWD"
          ''
        else
          # bash
          ''
            rm -f "$_SANDBOX_PASSWD"; ${networkCmds}
          '';
    in
    "trap '${cmds}' EXIT";

  # cacert and bashWrapper are always included: cacert so SSL/TLS
  # verification works, bashWrapper so the hardcoded SHELL and
  # /bin/sh symlink targets are always reachable in the store closure.
  # bashWrapper forces --norc --noprofile on every bash invocation so
  # that the sandboxed process cannot source /etc/bashrc or /etc/profile.
  # coreutils is included for /usr/bin/env (shebang resolution) only — it is
  # not in implicitPackages so it does not leak into PATH.
  closurePathsFile = pkgs.writeClosure (
    allowedPackages
    ++ implicitPackages
    ++ [
      pkg
      pkgs.coreutils
      preEntryScript
    ]
  );

  gitDetectionBashStr =
    # bash
    ''
      GIT_BIND=""
      REPO_BIND=""
      if GIT_DIR=$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        REPO_ROOT=$(dirname "$GIT_DIR")
        # Fail closed if the git root is $HOME (or an ancestor of it). Exposing it
        # would leak the entire home directory: REPO_ROOT is bound read-only and
        # GIT_DIR (=~/.git) read-write — and a home-rooted repo's object store holds
        # the history of tracked dotfiles (~/.ssh/config, tokens, etc.). There is no
        # safe partial exposure, so disable git for the session and warn instead.
        if [[ "$HOME" == "$REPO_ROOT" || "$HOME" == "$REPO_ROOT"/* ]]; then
          echo "${shared.warnPrefix} git root resolves to your home directory ($HOME) — refusing to expose it. git is disabled for this session." >&2
          # Empty so GIT_BIND/REPO_BIND stay unset and the `[[ -n ... ]]`
          # BOUND_PREFIXES guards below skip them too.
          GIT_DIR=""
          REPO_ROOT=""
        else
          # hooks/ and config are ro to prevent git hook injection: an agent
          # could otherwise drop an executable hook or set core.hooksPath to
          # redirect execution to a writable directory on the next host git op.
          GIT_BIND="--bind $GIT_DIR $GIT_DIR --ro-bind $GIT_DIR/hooks $GIT_DIR/hooks --ro-bind $GIT_DIR/config $GIT_DIR/config"
          REPO_BIND="--ro-bind $REPO_ROOT $REPO_ROOT"
        fi
      fi
    '';

in

builtins.seq
  (shared.assertNoLegacyArgs {
    restrictNetwork = restrictNetwork;
    extraEnv = extraEnv;
    stateDirs = stateDirs;
    stateFiles = stateFiles;
  })
  (
    pkgs.writeTextFile {
      name = outName;
      executable = true;
      destination = "/bin/${outName}";
      text =
        # bash
        ''
          #!${pkgs.bashInteractive}/bin/bash
            CWD=$(pwd)
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

          ${symlinkResolutionBashStr}
          ${sandboxPasswdBashStr}
          ${conditionalNetworkingParams.proxyStartupBashStr}
          ${conditionalNetworkingParams.resolvConfSetupBashStr}
          ${trapBashStr}
          ${conditionalNetworkingParams.sandboxExecBashStr}${pkgs.coreutils}/bin/env -i ${pkgs.bubblewrap}/bin/bwrap \
            ${conditionalNetworkingParams.etcResolvBind} \
            --tmpfs /nix/store \
            $CLOSURE_BINDS \
            --ro-bind "$_SANDBOX_PASSWD" /etc/passwd \
            --ro-bind ${hostsFile} /etc/hosts \
            --ro-bind-try /etc/ssl/certs /etc/ssl/certs \
            --ro-bind-try /etc/static /etc/static \
            --ro-bind-try /etc/pki /etc/pki \
            --proc /proc \
            --ro-bind ${emptyFile} /proc/cmdline \
            --ro-bind ${emptyFile} /proc/sys/kernel/random/boot_id \
            --dev /dev \
            --tmpfs /tmp \
            --tmpfs "$HOME" \
            $REPO_BIND \
            --bind "$CWD" "$CWD" \
            ${bindDirsStr} \
            $STATE_FILE_BINDS \
            $SYMLINK_PARENT_DIRS \
            $readonlyStateFileSymlinks \
            $GIT_BIND \
            --symlink ${bashWrapper}/bin/bash /bin/sh \
            --symlink ${pkgs.coreutils}/bin/env /usr/bin/env \
            --unshare-all \
            --hostname sandbox \
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
            --setenv GIT_CONFIG_COUNT 1 \
            --setenv GIT_CONFIG_KEY_0 user.useConfigOnly \
            --setenv GIT_CONFIG_VALUE_0 true \
            ${conditionalNetworkingParams.sslCertEnvBubblewrapStr} \
            ${conditionalNetworkingParams.caCertBubblewrapStr} \
            ${conditionalNetworkingParams.proxyEnvBubblewrapStr} \
            ${extraEnvStr} \
            ${preEntryScript} ${pkg}/bin/${binName} "$@"
        '';
    }
  )
