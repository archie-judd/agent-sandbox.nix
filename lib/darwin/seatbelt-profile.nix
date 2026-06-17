# lib/seatbelt-profile.nix — static Seatbelt (sandbox-exec) profile rules for
# mkDarwinSandbox. Per-closure store-path rules are appended at Nix build time
# by the runCommand builder in default.nix.
#
# Arguments:
#   networkRulesStr      — (allow network*) or restricted-proxy rules
#   nixSupportRulesStr   — Nix daemon socket + full-store exec rules when
#                          allowNix is set; empty string otherwise
#   allowReadWriteExecStr — per-rwDir allow rules  (subpath, file-read/write/exec)
#   allowFilesStr        — per-rwFile allow rules  (literal, file-read/write)
#   allowReadOnlyStr      — per-roDir allow rules  (subpath, file-read*; no exec)
#   allowFilesReadOnlyStr — per-roFile allow rules (literal, file-read*)
{
  networkRulesStr,
  nixSupportRulesStr,
  allowReadWriteExecStr,
  allowFilesStr,
  allowReadOnlyStr,
  allowFilesReadOnlyStr,
}:
# scheme
''
  (version 1)
  (deny default)

  ;; Process control
  (allow process-fork)
  (allow signal)

  ;; sysctls — broad read, with explicit denies for the process-snooping
  ;; OIDs. Without these, sysctl({1, 49, pid}) (KERN_PROCARGS2) returns
  ;; the full argv+envp of any host-UID process — a complete exfil path
  ;; for env-var secrets the host shell has set (CLAUDE_CODE_OAUTH_TOKEN,
  ;; GITHUB_TOKEN, AWS_*, …) before launching the sandbox. The integer-
  ;; MIB form of sysctl(2) resolves to the same canonical names
  ;; internally, so the name-deny catches both sysctl() and sysctlbyname()
  ;; callers. seatbelt is last-match-wins, so the denies override the
  ;; blanket allow.
  ;;
  ;; Host-identifying single OIDs (kern.hostname, kern.uuid, hw.model,
  ;; kern.boottime, …) are intentionally NOT denied here — seatbelt does
  ;; not appear to intercept them through this filter, and denying
  ;; kern.hostname in particular breaks uname(2) (which reads hostname
  ;; as part of a single struct). They remain an accepted leak.
  (allow sysctl-read)
  (deny sysctl-read
    (sysctl-name "kern.procargs")     ;; deprecated argv reader
    (sysctl-name "kern.procargs2")    ;; argv + envp of any host-UID process
    (sysctl-name-regex #"^kern\.proc\."))  ;; kern.proc.all, kern.proc.pid.*, etc.

  ;; Process execution — per-store-path rules are appended by the builder
  (allow process-exec (subpath (param "CWD")))
  (allow process-exec (literal "/bin/sh"))
  (allow process-exec (literal "/bin/bash"))
  (allow process-exec (literal "/usr/bin/env"))

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

  ${networkRulesStr}

  ;; Nix daemon support (only when allowNix is set). Emitted after the
  ;; network rules so the socket allow wins over the blanket
  ;; (deny network-outbound (remote unix-socket)) in unrestricted mode
  ;; (seatbelt is last-match-wins), and supplies the missing permission
  ;; in restricted (proxy) mode. The process-exec grant covers the whole
  ;; store so the agent can exec results built by the daemon after sandbox
  ;; start (e.g. `nix-shell -p`) — paths that aren't in the
  ;; allowedPackages closure.
  ${nixSupportRulesStr}

  ;; Device nodes & terminal I/O
  (allow file-read*
    (literal "/dev/null")
    (literal "/dev/urandom")
    (literal "/dev/random")
    (literal "/dev/zero")
    (literal "/dev/ptmx")
    (literal "/private/var/select/sh"))
  (allow file-write* (literal "/dev/null"))
  ;; /dev/tty (the controlling-terminal alias) is intentionally NOT allowed:
  ;; it lets a process bypass piped stdin to prompt the human directly, and
  ;; opens the door to escape-sequence/TIOCSTI injection into the parent
  ;; shell. The legacy BSD pty families (/dev/pty*, /dev/ttyp*, /dev/ttyq*,
  ;; /dev/ttyr*) are likewise omitted — modern macOS allocates via
  ;; /dev/ptmx + /dev/ttysNNN exclusively.
  ;;
  ;; Access to the modern pty slave (/dev/ttysNNN) is pinned to the single
  ;; tty the wrapper was launched on, via (param "MY_TTY"). When stdin is
  ;; not a tty the wrapper passes a nonexistent path so no slave is
  ;; reachable. This prevents a sandboxed process from opening another
  ;; Terminal/iTerm/tmux pane's pty owned by the same UID
  ;; (escape-sequence injection, TIOCSTI input injection, keystroke
  ;; eavesdropping).
  (allow file-read* file-write*
    (literal "/dev/ptmx")
    (regex #"^/dev/fd/")
    (literal (param "MY_TTY")))
  (allow file-ioctl
    (literal "/dev/ptmx")
    (literal (param "MY_TTY")))
  (allow file-read-metadata
    (literal "/dev/stdout")
    (literal "/dev/stderr")
    (literal "/dev/stdin")
    (literal "/dev/dtracehelper"))

  ;; System libraries & frameworks. /Library/Preferences is intentionally NOT
  ;; allowed: it holds host-identifying plists (hostname, MAC addresses,
  ;; paired Bluetooth devices, recent users, WiFi private-MAC rotation keys).
  (allow file-read*
    (subpath "/usr/lib")
    (subpath "/usr/bin")
    (subpath "/usr/share")
    (subpath "/bin")
    (subpath "/System"))

  ;; ...but NOT /System/Volumes/*. On Tahoe (and Catalina+), the data volume
  ;; mounts at /System/Volumes/Data, with /Library, /Users, /private/var
  ;; firmlinked from there. The broad /System allow above would otherwise
  ;; expose the entire data volume via its canonical Data-volume address,
  ;; bypassing every narrower deny on the synthetic /Library/Preferences,
  ;; /Users/<u>, /private/var/folders paths. Last-match-wins, so this deny
  ;; overrides the allow above.
  (deny file-read* (subpath "/System/Volumes"))

  ;; DNS, TLS & name resolution
  (allow file-read*
    (literal "/private/etc/resolv.conf")
    (literal "/private/var/run/resolv.conf")
    (subpath "/private/etc/ssl")
    (literal (param "SANDBOX_PASSWD"))
    (literal "/private/etc/localtime")
    (subpath "/private/etc/static")
    (literal "/private/etc/hosts"))

  ;; Security framework — system keychains & trust databases
  (allow file-read*
    (subpath "/private/var/db/mds")
    (subpath "/Library/Keychains")
    (literal "/private/var/run/systemkeychaincheck.done"))

  ;; Temp directories. /private/var/folders (the macOS per-user temp/cache
  ;; tree returned by confstr(_CS_DARWIN_USER_*)) is intentionally NOT
  ;; allowed: it holds 0400/0600 user secrets reachable via the host UID.
  (allow file-read* file-write*
    (subpath "/tmp")
    (subpath "/private/tmp")
    (subpath (param "TMPDIR")))

  ;; Nix store — full read access so symlinks into the store (e.g.
  ;; home-manager-managed config files) are followable. Execution is
  ;; still restricted to the allowed closure below.
  (allow file-read-metadata
    (literal "/nix")
    (literal "/nix/store"))
  (allow file-read* (subpath "/nix/store"))

  ;; Filesystem traversal — stat() on parent dirs for path resolution.
  ;; "/" needs file-read* (process startup requires readdir on root).
  ;; All other traversal paths use file-read-metadata so only stat() is
  ;; allowed, preventing readdir() from enumerating directory contents.
  (allow file-read* (literal "/"))
  (allow file-read-metadata
    (literal "/var")
    (literal "/dev")
    (literal "/private")
    (literal "/private/var")
    (literal "/etc")
    (literal "/private/etc")
    (literal "/private/var/db")
    (literal "/Users")
    (literal (param "REAL_HOME"))
    (literal (param "HOME_LOCAL"))
    (literal (param "HOME_CACHE"))
    (literal (param "HOME_LOCAL_SHARE"))
    (literal (param "HOME_LOCAL_STATE"))
    (literal (param "REPO_ROOT_PARENT")))

  ;; Sandbox HOME — full read + exec (copilot stores spawn helper binaries here) 
  (allow file-read* process-exec (subpath (param "HOME")))

  ;; Working directory & repository
  (allow file-read* file-write* (subpath (param "CWD")))
  (allow file-read* (subpath (param "REPO_ROOT")))
  (allow file-read* file-write* (subpath (param "GIT_DIR")))
  ;; Narrow the common-gitdir write grant: hooks/ and config are the
  ;; persistence vectors a sandboxed process could use to fire arbitrary
  ;; code the next time the host user runs git here (and from any
  ;; worktree — --git-common-dir resolves to the same path). Writing
  ;; hooks/post-checkout, or setting core.hooksPath / alias.* = !cmd /
  ;; gpg.program / filter.*.smudge in config, would all execute on the
  ;; host. Reads stay allowed (seatbelt is last-match-wins) so git can
  ;; still run the hooks and read the config it already has; commits and
  ;; fetches still work because they write objects/ and refs/, not these.
  (deny file-write* (subpath (param "GIT_HOOKS_DIR")))
  (deny file-write* (literal (param "GIT_CONFIG_FILE")))

  ;; Timezone
  (allow file-read* (subpath "/private/var/db/timezone"))

  ;; Explicit state directories & files
  ${allowReadWriteExecStr}
  ${allowFilesStr}

  ;; Read-only directories & files
  ${allowReadOnlyStr}
  ${allowFilesReadOnlyStr}
''
