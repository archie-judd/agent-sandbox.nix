#!@bash@
# The interpreter is pinned, not resolved from PATH. macOS ships bash 3.2,
# which has no mapfile at all, so `/usr/bin/env bash` turns this into a
# script that silently assembles an empty command line.
# shellcheck shell=bash
#
# What $out/bin/<outName> actually is. Identical for every wrapper and both
# platforms: the only build-time substitutions are four store paths and the
# error prefix, and it holds no logic beyond resolving the declared environment
# and assembling one command line.
#
# Everything it needs, it finds by fixed name in the session directory that
# `prepare` prints. The one runtime branch is on an artifact's existence, not
# on anything decided at build time.
#
# No `set -e`. The last command is the sandbox, and its exit status is the
# status of this script; an errexit would turn a nonzero agent exit into an
# abort before the trap could run.
set -uo pipefail

# One `declare_env NAME '"<expression>"'` line per declared variable, generated
# by Nix. The values are documented as runtime shell expressions, so they expand
# here and never enter Python or touch disk.
#
# Resolved before `prepare` runs. An unresolvable value is a failed launch
# either way, and failing now means there is no session directory to record and
# no proxy to tear down.
DECLARED_ENV=()
UNRESOLVED=()

declare_env() {
  local name=$1 expression=$2 value
  # The expansion runs inside a command substitution so that `set -u` on an
  # unset variable kills only the subshell. Sourcing the assignment directly
  # aborts the whole stub with bash's own message, which names the fragment's
  # store path rather than the env attribute and stops at the first failure.
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
    echo "Each value is a shell expression evaluated at launch, so anything it"
    echo "references must be set in the shell you launch from."
  } >&2
  exit 1
fi

# Exported rather than set per command, so the entry point that runs inside
# pasta's namespace inherits it too. `env -i` clears it before bubblewrap, so
# the sandbox never sees it.
export PYTHONPATH=@launcher@

if ! SESSION_DIR=$("@python@" -P -s -S -m launcher.prepare "@spec@"); then
  exit 1
fi

# The one thing the stub writes. Session directories outlive their run, so a
# later launch prunes the oldest, and it has to be able to tell a finished
# session from one still going: this shell does not exec, so it is the
# sandbox's parent until the session ends and its pid answers that.
echo $$ >"$SESSION_DIR/stub.pid"

# Armed only now: before this point there is no session to clean up, and
# prepare tears down its own failures.
trap '"@python@" -P -s -S -m launcher.cleanup "$SESSION_DIR"' EXIT

mapfile -d '' ARGV_BEFORE_ENV < "$SESSION_DIR/argv-before-env"
mapfile -d '' ARGV_AFTER_ENV < "$SESSION_DIR/argv-after-env"

"${ARGV_BEFORE_ENV[@]}" "${DECLARED_ENV[@]}" "${ARGV_AFTER_ENV[@]}" "$@"
