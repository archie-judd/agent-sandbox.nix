#!@bash@
# Pinned interpreter: macOS ships bash 3.2, which has no mapfile, so
# `/usr/bin/env bash` would silently assemble an empty command line.
# shellcheck shell=bash
#
# No `set -e`: the last command is the sandbox, and its exit status is the
# status of this script.
set -uo pipefail

DECLARED_ENV=()
UNRESOLVED=()

# The declared env values are runtime shell expressions; they expand here and
# never enter Python or touch disk. The expansion runs inside a command
# substitution so that `set -u` on an unset variable kills only the subshell,
# letting every failure be collected and reported against its env attribute.
declare_env() {
  local name=$1 expression=$2 value
  if value=$(eval "printf '%s' $expression" 2>/dev/null); then
    DECLARED_ENV+=("$name=$value")
  else
    UNRESOLVED+=("$name = $expression")
  fi
}

# shellcheck source=/dev/null
source "@envFragment@"

if ((${#UNRESOLVED[@]})); then
  {
    echo "@errorPrefix@ could not resolve these env values:"
    echo
    for entry in "${UNRESOLVED[@]}"; do
      echo "  $entry"
    done
    echo
    echo "Each value is a shell expression evaluated at launch; anything it"
    echo "references must be set in the shell you launch from."
  } >&2
  exit 1
fi

# bash sets PWD but does not export it, and the default workspaceDir is
# "$PWD". An undefined variable is fatal in the launcher's expansion, so
# without this anything exec'ing the wrapper with a clean environment would
# break the default configuration rather than an unusual one.
export PWD

# Exported so the entry point inside pasta's namespace inherits it too;
# `env -i` clears it before bubblewrap.
export PYTHONPATH=@launcher@

if ! SESSION_DIR=$("@python@" -P -s -S -m launcher.prepare "@spec@"); then
  exit 1
fi

# This shell does not exec, so it is the sandbox's parent until the session
# ends; its pid is how a later launch's prune tells a finished session from a
# running one.
echo $$ >"$SESSION_DIR/stub.pid"

# Armed only now: before this point there is no session to clean up, and
# prepare tears down its own failures. $? is captured first because it is the
# sandbox's exit status, and every command in the trap body overwrites it.
trap 'STATUS=$?; "@python@" -P -s -S -m launcher.cleanup "$SESSION_DIR" "$STATUS"' EXIT

mapfile -d '' ARGV_BEFORE_ENV < "$SESSION_DIR/argv-before-env"
mapfile -d '' ARGV_AFTER_ENV < "$SESSION_DIR/argv-after-env"

"${ARGV_BEFORE_ENV[@]}" "${DECLARED_ENV[@]}" "${ARGV_AFTER_ENV[@]}" "$@"
