# lib/symlink-helpers.nix — bash helper functions for resolving symlink chains
# at sandbox startup, and per-item generators used by mkLinuxSandbox.
#
# The three shell functions must be emitted in order after BOUND_PREFIXES is
# populated: isAlreadyBoundBashStr, then addSymlinkTargetBashStr (which also
# initialises the runtime variables), then followSymlinkChainBashStr.
{ pkgs, shared }:
{
  # Checks whether a path is already covered by one of the bound prefixes.
  isAlreadyBoundBashStr =
    # bash
    ''
      _is_already_bound() {
        local _target="$1"
        local _prefix
        for _prefix in "''${BOUND_PREFIXES[@]}"; do
          [[ "$_target" == "$_prefix" || "$_target" == "$_prefix/"* ]] && return 0
        done
        return 1
      }
    '';

  # Initialises the output variables, then defines _ensure_parent_dirs (emits
  # --dir entries for a path's ancestors) and _add_symlink_target (appends a
  # resolved nix store path and its missing parent dirs to the output vars).

  addSymlinkTargetBashStr =
    # bash
    ''
      RESOLVED_TARGETS=()
      SEEN_PARENT_DIRS=()
      readonlyStateFileSymlinks=""
      SYMLINK_PARENT_DIRS=""

      # Emit --dir entries for each ancestor of _path that bwrap has not already
      # been told about. Needed whenever a file is bound at a path whose parent
      # dirs don't exist in the sandbox yet (e.g. under an ephemeral $HOME tmpfs).
      # SEEN_PARENT_DIRS dedupes without affecting bind decisions.
      _ensure_parent_dirs() {
        local _path="$1"
        local _dir _seen _existing
        _dir=$(dirname "$_path")
        while [[ "$_dir" != "/" ]]; do
          _is_already_bound "$_dir" && break
          _seen=0
          for _existing in "''${SEEN_PARENT_DIRS[@]}"; do
            [[ "$_existing" == "$_dir" ]] && { _seen=1; break; }
          done
          (( _seen )) && break
          SYMLINK_PARENT_DIRS="$SYMLINK_PARENT_DIRS --dir $_dir"
          SEEN_PARENT_DIRS+=("$_dir")
          _dir=$(dirname "$_dir")
        done
      }

      _add_symlink_target() {
        local _target="$1"
        local _existing
        for _existing in "''${RESOLVED_TARGETS[@]}"; do
          [[ "$_existing" == "$_target" ]] && return
        done
        RESOLVED_TARGETS+=("$_target")
        _is_already_bound "$_target" && return
        # Reject targets outside the declared sandbox paths. This prevents an
        # agent from planting a symlink (in a stateDir or via a stateFile) that
        # expands the sandbox on the next startup (e.g. ~/.claude/evil -> /etc/shadow).
        # Nix store paths are exempt: they are immutable and agent-unwritable.
        if [[ "$_target" != /nix/store/* ]]; then
          echo "${shared.warnPrefix} ignoring symlink to '$_target' — target is outside permitted paths; declare it as a rwDir, rwFile, roDir or roFile to allow access" >&2
          return
        fi
        readonlyStateFileSymlinks="$readonlyStateFileSymlinks --ro-bind $_target $_target"
        # Emit --dir entries for ancestor dirs so bwrap has mountpoints. These
        # ancestors are NOT added to BOUND_PREFIXES: --dir only creates an empty
        # dir, it does not expose its contents, so sibling files under the same
        # ancestor still need their own --ro-bind.
        _ensure_parent_dirs "$_target"
      }
    '';

  # Walks a symlink chain hop-by-hop, binding each intermediate target.
  # Unlike readlink -f (which returns only the final target), this ensures
  # every path in the chain is accessible inside the sandbox.
  followSymlinkChainBashStr =
    # bash
    ''
      _follow_symlink_chain() {
        local _path="$1"
        local _max_hops=40
        local _hop=0

        while [[ -L "$_path" ]] && (( _hop++ < _max_hops )); do
          local _next
          _next=$(${pkgs.coreutils}/bin/readlink "$_path")

          # Convert relative symlink to absolute path
          if [[ "$_next" != /* ]]; then
            _next="$(dirname "$_path")/$_next"
          fi

          # Normalize path (resolve . and ..)
          _next=$(cd "$(dirname "$_next")" 2>/dev/null && pwd)/$(basename "$_next") || true
          [[ -z "$_next" || "$_next" == "/" ]] && break

          _add_symlink_target "$_next"
          _path="$_next"
        done
      }
    '';

  # Per-rwFile: if it is a symlink, walk its chain via _follow_symlink_chain
  # and then bind the final nix store target at the declared path so the file
  # is accessible where callers expect it. Otherwise bind directly.
  # Appends to STATE_FILE_BINDS at runtime.
  #
  # The bind at the declared path is skipped when an enclosing bind (typically
  # CWD, when the agent is launched from $HOME) already exposes the real
  # symlink. bwrap resolves mount destinations against its own intermediate
  # root, where an absolute symlink target does not exist, so it cannot create
  # a mountpoint on top of one and dies with "Can't create file at ...". No
  # ordering of the binds avoids this. Nothing is lost by skipping: the
  # covering bind exposes the symlink, and _follow_symlink_chain has bound its
  # targets, so the file resolves inside the sandbox anyway.
  #
  # The test is on the parent, not the path itself: declared dirs are their own
  # entries in BOUND_PREFIXES, so asking about the path would always say yes.
  mkResolveFileBashStr =
    file:
    # bash
    ''
      if [[ -L "${file}" ]]; then
        _follow_symlink_chain "${file}"
        if ! _is_already_bound "$(dirname "${file}")"; then
          _final=$(${pkgs.coreutils}/bin/readlink -f "${file}" 2>/dev/null)
          if [[ "$_final" == /nix/store/* ]]; then
            STATE_FILE_BINDS="$STATE_FILE_BINDS --bind $_final ${file}"
            _ensure_parent_dirs "${file}"
          fi
        fi
      else
        STATE_FILE_BINDS="$STATE_FILE_BINDS --bind ${file} ${file}"
      fi
    '';

  # Per-roFile: same shape as mkResolveFileBashStr but binds read-only.
  mkResolveRoFileBashStr =
    file:
    # bash
    ''
      if [[ -L "${file}" ]]; then
        _follow_symlink_chain "${file}"
        if ! _is_already_bound "$(dirname "${file}")"; then
          _final=$(${pkgs.coreutils}/bin/readlink -f "${file}" 2>/dev/null)
          if [[ "$_final" == /nix/store/* ]]; then
            RO_FILE_BINDS="$RO_FILE_BINDS --ro-bind $_final ${file}"
            _ensure_parent_dirs "${file}"
          fi
        fi
      else
        RO_FILE_BINDS="$RO_FILE_BINDS --ro-bind ${file} ${file}"
      fi
    '';

  # Per-rwDir: bind the declared path, except when the dir is itself a symlink
  # whose parent is already bound — the same unmountable-destination case the
  # file generators above avoid. A non-symlink dir is always bound, so a roDir
  # keeps its read-only mode even inside a read-write CWD.
  # Appends to STATE_DIR_BINDS at runtime.
  mkResolveDirBashStr =
    dir:
    # bash
    ''
      if [[ -L "${dir}" ]]; then
        _follow_symlink_chain "${dir}"
        if ! _is_already_bound "$(dirname "${dir}")"; then
          STATE_DIR_BINDS="$STATE_DIR_BINDS --bind ${dir} ${dir}"
        fi
      else
        STATE_DIR_BINDS="$STATE_DIR_BINDS --bind ${dir} ${dir}"
      fi
    '';

  # Per-roDir: same shape as mkResolveDirBashStr but binds read-only.
  mkResolveRoDirBashStr =
    dir:
    # bash
    ''
      if [[ -L "${dir}" ]]; then
        _follow_symlink_chain "${dir}"
        if ! _is_already_bound "$(dirname "${dir}")"; then
          RO_DIR_BINDS="$RO_DIR_BINDS --ro-bind ${dir} ${dir}"
        fi
      else
        RO_DIR_BINDS="$RO_DIR_BINDS --ro-bind ${dir} ${dir}"
      fi
    '';

  # Per-stateDir: scan for top-level symlinks inside the bound dir and walk
  # each symlink chain via _follow_symlink_chain.
  mkScanDirBashStr =
    dir:
    # bash
    ''
      while IFS= read -r _symlink; do
        _follow_symlink_chain "$_symlink"
      done < <(${pkgs.findutils}/bin/find "${dir}" -maxdepth 1 -type l 2>/dev/null)
    '';
}
