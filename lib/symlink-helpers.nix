# lib/symlink-helpers.nix — bash helper functions for resolving symlink chains
# at sandbox startup, and per-item generators used by mkLinuxSandbox.
#
# The three shell functions must be emitted in order after BOUND_PREFIXES is
# populated: isAlreadyBoundBashStr, then addSymlinkTargetBashStr (which also
# initialises the runtime variables), then followSymlinkChainBashStr.
{ pkgs }:
{
  # Checks whether a path is already covered by one of the bound prefixes.
  isAlreadyBoundBashStr = ''
    _is_already_bound() {
      local _target="$1"
      local _prefix
      for _prefix in "''${BOUND_PREFIXES[@]}"; do
        [[ "$_target" == "$_prefix" || "$_target" == "$_prefix/"* ]] && return 0
      done
      return 1
    }
  '';

  # Initialises the output variables, then defines _add_symlink_target which
  # appends a resolved path (and its missing parent dirs) to those variables.
  addSymlinkTargetBashStr = ''
    RESOLVED_TARGETS=()
    readonlyStateFileSymlinks=""
    readWriteStateFileSymlinks=""
    SYMLINK_PARENT_DIRS=""

    _add_symlink_target() {
      local _target="$1"
      local _existing
      for _existing in "''${RESOLVED_TARGETS[@]}"; do
        [[ "$_existing" == "$_target" ]] && return
      done
      RESOLVED_TARGETS+=("$_target")
      _is_already_bound "$_target" && return
      if [[ "$_target" == /nix/store/* ]]; then
        readonlyStateFileSymlinks="$readonlyStateFileSymlinks --ro-bind $_target $_target"
      else
        readWriteStateFileSymlinks="$readWriteStateFileSymlinks --bind $_target $_target"
      fi
      local _dir
      _dir=$(dirname "$_target")
      while [[ "$_dir" != "/" ]]; do
        _is_already_bound "$_dir" && break
        SYMLINK_PARENT_DIRS="$SYMLINK_PARENT_DIRS --dir $_dir"
        BOUND_PREFIXES+=("$_dir")
        _dir=$(dirname "$_dir")
      done
    }
  '';

  # Walks a symlink chain hop-by-hop, binding each intermediate target.
  # Unlike readlink -f (which returns only the final target), this ensures
  # every path in the chain is accessible inside the sandbox.
  followSymlinkChainBashStr = ''
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

  # Per-stateFile: if it is a symlink, walk its chain via _follow_symlink_chain;
  # otherwise bind directly. Appends to STATE_FILE_BINDS at runtime.
  mkResolveFileBashStr = file: ''
    if [[ -L "${file}" ]]; then
      _follow_symlink_chain "${file}"
    else
      STATE_FILE_BINDS="$STATE_FILE_BINDS --bind ${file} ${file}"
    fi
  '';

  # Per-stateDir: recursively scan for symlinks inside the bound dir and walk
  # each symlink chain via _follow_symlink_chain.
  mkScanDirBashStr = dir: ''
    while IFS= read -r _symlink; do
      _follow_symlink_chain "$_symlink"
    done < <(${pkgs.findutils}/bin/find "${dir}" -type l 2>/dev/null)
  '';
}
