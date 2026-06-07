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
       /dev/ptmx and /dev/fd/* for pty allocation and fd-numbered access.
       The pty slave (/dev/ttysNNN) is restricted to the single tty the
       wrapper was launched on, injected as -D MY_TTY=<path> and
       referenced by the profile as (param "MY_TTY"). When stdin is not
       a tty the wrapper passes /nonexistent-tty so no slave is reachable.
       /dev/tty itself is NOT allowed — it lets a process bypass piped
       stdin to talk to the human and is the classic vector for
       escape-sequence / TIOCSTI injection into the parent shell. The
       legacy BSD pty families (/dev/pty*, /dev/ttyp*, /dev/ttyq*,
       /dev/ttyr*) are also omitted; modern macOS uses /dev/ptmx +
       /dev/ttysNNN exclusively.

     System libraries:
       /usr/lib, /usr/share, /System — Apple frameworks and dylibs.
       These are read-only. Without them, almost nothing runs on macOS.
       /Library/Preferences is intentionally NOT allowed: its plists leak
       host identity (hostname, MAC addresses, paired Bluetooth devices,
       recent users, WiFi rotation key material).

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
       /tmp, /private/tmp, and $TMPDIR (injected as /tmp via -D).
       All are read-write. The per-user /private/var/folders tree —
       where confstr(_CS_DARWIN_USER_TEMP_DIR / _CACHE_DIR) resolves
       to — is intentionally NOT allowed: it holds host-user secrets
       (age keys, PATs, etc.) reachable because sandbox-exec can't
       drop UID. Tools must respect $TMPDIR.

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
{ pkgs, shared }:
{ pkg, binName, outName, allowedPackages, stateDirs ? [ ], stateFiles ? [ ]
, extraEnv ? { }, restrictNetwork ? false, allowedDomains ? [ ]
  # Internal: maps "host" → "addr:port" so the proxy dials the local address
  # for those hosts instead of resolving the original. Used by the test
  # harness to point fake domains at a local httpbin. Not part of the
  # public API — leading underscore signals internal-only.
, _proxyRedirects ? { } }:
let
  bashWrapper = shared.bashWrapper;
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

  seatbeltAllowFiles = builtins.concatStringsSep "\n"
    (map (p: ''(allow file-read* file-write* (literal (param "${p.name}")))'')
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

  mkDirsStr =
    builtins.concatStringsSep "\n" (map (dir: ''mkdir -p "${dir}"'') stateDirs);
  mkFilesStr =
    builtins.concatStringsSep "\n" (map (file: ''touch "${file}"'') stateFiles);

  extraEnvInlineStr = builtins.concatStringsSep " \\\n        "
    (map (name: "${name}=${builtins.toJSON extraEnv.${name}}")
      (builtins.attrNames extraEnv));

  conditionalNetworkingParams = import ./networking.nix {
    pkgs = pkgs;
    shared = shared;
    restrictNetwork = restrictNetwork;
    allowedDomains = allowedDomains;
    _proxyRedirects = _proxyRedirects;
  };

  # cacert and bashWrapper are always included: cacert so SSL/TLS
  # verification works, bashWrapper so the hardcoded SHELL target
  # is always reachable in the store closure. bashWrapper forces
  # --norc --noprofile on every bash invocation so that the sandboxed
  # process cannot source /etc/bashrc or /etc/profile.
  closurePathsFile =
    pkgs.writeClosure (allowedPackages ++ implicitPackages ++ [ pkg ]);

  gitDetectionBashStr =
    # bash
    ''
      if GIT_DIR=$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
          GIT_DIR_PARAM="$GIT_DIR"
          GIT_HOOKS_DIR_PARAM="$GIT_DIR/hooks"
          GIT_CONFIG_FILE_PARAM="$GIT_DIR/config"
          REPO_ROOT=$(dirname "$GIT_DIR_PARAM")
          REPO_ROOT_PARENT=$(dirname "$REPO_ROOT")
      else
          GIT_DIR_PARAM="/nonexistent-git-dir"
          GIT_HOOKS_DIR_PARAM="/nonexistent-git-hooks-dir"
          GIT_CONFIG_FILE_PARAM="/nonexistent-git-config-file"
          REPO_ROOT="/nonexistent-repo-root"
          REPO_ROOT_PARENT="/nonexistent-repo-root"
      fi
    '';

  # Pin the seatbelt /dev/ttys* allow rule to the single pty slave the
  # wrapper was launched on. When stdin is piped/redirected, fall back to
  # a nonexistent path so the rule matches nothing.
  ttyDetectionBashStr =
    # bash
    ''
      if _tty=$(tty 2>/dev/null) && [[ "$_tty" == /dev/* ]]; then
          MY_TTY="$_tty"
      else
          MY_TTY="/nonexistent-tty"
      fi
    '';

  # Walk from one directory up to an ancestor, collecting intermediate
  # directories that need file-read-metadata for seatbelt path traversal.
  # Both arguments are bash expressions (e.g. "$REPO_ROOT", "$REAL_HOME").
  mkTraversalBashStr = fromDescendant: toAncestor: ''
    _CURRENT=$(dirname "${fromDescendant}")
    while [ "$_CURRENT" != "${toAncestor}" ] && [ "$_CURRENT" != "/" ]; do
      ANCESTOR_DIRS+=("$_CURRENT")
      _CURRENT=$(dirname "$_CURRENT")
    done
  '';

  # Collect ancestors for repo root (or CWD) → REAL_HOME, plus
  # each stateDir/stateFile → REAL_HOME so symlink targets are reachable.
  ancestorTraversalBashStr =
    let
      stateDirTraversals = builtins.concatStringsSep "\n"
        (map (p: mkTraversalBashStr "$_RESOLVED_${p.name}" "$REAL_HOME") stateDirParams);
      stateFileTraversals = builtins.concatStringsSep "\n"
        (map (p: mkTraversalBashStr "$_RESOLVED_${p.name}" "$REAL_HOME") stateFileParams);
    in
    # bash
    ''
      _WALK_FROM="$REPO_ROOT"
      if [ "$_WALK_FROM" = "/nonexistent-repo-root" ]; then
        _WALK_FROM="$CWD"
      fi
      ANCESTOR_DIRS=()
      ${mkTraversalBashStr "$_WALK_FROM" "$REAL_HOME"}
      ${stateDirTraversals}
      ${stateFileTraversals}
    '';

  # Copy the static seatbelt profile to a temp file and append
  # file-read-metadata rules for each ancestor directory at runtime.
  ancestorProfilePatchBashStr =
    # bash
    ''
      SANDBOX_PROFILE=$(mktemp /tmp/sandbox-profile-XXXXXX)
      cp ${seatbeltProfile} "$SANDBOX_PROFILE"
      for _dir in "''${ANCESTOR_DIRS[@]}"; do
        printf '    (allow file-read-metadata (literal "%s"))\n' "$_dir" >> "$SANDBOX_PROFILE"
      done
    '';
  seatbeltStaticRules = import ./seatbelt-profile.nix {
    networkRulesStr = conditionalNetworkingParams.networkSeatbeltRulesStr;
    allowReadWriteExecStr = seatbeltAllowReadWriteExec;
    allowFilesStr = seatbeltAllowFiles;
  };

  seatbeltProfile = pkgs.runCommand "${outName}-sandbox.sb" {
    closurePaths = closurePathsFile;
    staticRules = seatbeltStaticRules;
  }
  # bash
    ''
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
  text =
    # bash
    ''
      #!${pkgs.bashInteractive}/bin/bash
      CWD=$(pwd)
      ${conditionalNetworkingParams.warnIgnoredDomainsBashStr}

      # Ensure stateDirs/stateFiles exist while HOME still points at real home
      ${mkDirsStr}
      ${mkFilesStr}

      ${gitDetectionBashStr}
      ${ttyDetectionBashStr}

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
      ${conditionalNetworkingParams.networkRuntimePatchBashStr}
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
        -D GIT_HOOKS_DIR="$GIT_HOOKS_DIR_PARAM" \
        -D GIT_CONFIG_FILE="$GIT_CONFIG_FILE_PARAM" \
        -D REPO_ROOT="$REPO_ROOT" \
        -D REPO_ROOT_PARENT="$REPO_ROOT_PARENT" \
        -D MY_TTY="$MY_TTY" \
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
}
