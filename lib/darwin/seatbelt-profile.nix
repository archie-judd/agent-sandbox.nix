# lib/seatbelt-profile.nix — static Seatbelt (sandbox-exec) profile rules for
# mkDarwinSandbox. Per-closure store-path rules are appended at Nix build time
# by the runCommand builder in default.nix.
#
# Arguments:
#   networkRulesStr      — (allow network*) or restricted-proxy rules
#   allowReadWriteExecStr — per-stateDir allow rules  (subpath, file-read/write/exec)
#   allowFilesStr        — per-stateFile allow rules  (literal, file-read/write)
{ networkRulesStr, allowReadWriteExecStr, allowFilesStr }: ''
  (version 1)
  (deny default)

  ;; Process control
  (allow process-fork)
  (allow signal)
  (allow sysctl-read)

  ;; Process execution — per-store-path rules are appended by the builder
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

  ${networkRulesStr}

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

  ;; System libraries & frameworks
  (allow file-read*
    (subpath "/usr/lib")
    (subpath "/usr/bin")
    (subpath "/usr/share")
    (subpath "/bin")
    (subpath "/System")
    (subpath "/Library/Preferences"))

  ;; DNS, TLS & name resolution
  (allow file-read*
    (literal "/private/etc/resolv.conf")
    (literal "/private/var/run/resolv.conf")
    (subpath "/private/etc/ssl")
    (literal "/private/etc/passwd")
    (literal "/private/etc/localtime")
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
  (allow file-read* (subpath (param "GIT_CONFIG_DIR")))

  ;; Timezone
  (allow file-read* (subpath "/private/var/db/timezone"))

  ;; Explicit state directories & files
  ${allowReadWriteExecStr}
  ${allowFilesStr}
''
