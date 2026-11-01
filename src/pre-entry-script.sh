# shellcheck shell=bash
# First process inside the sandbox. Argv is <workspace-dir> <binary> [args...].
#
# The chdir lives here because macOS has no other place to put it: argv is
# handed to sandbox-exec, and BSD /usr/bin/env has no --chdir. Linux passes
# --chdir to bubblewrap as well, so there this is a no-op — one contract on
# both platforms beats two mechanisms.
cd "$1" || exit 1
shift

# Warns at launch when no git identity resolves; with user.useConfigOnly set,
# `git commit` fails closed rather than fabricating one.
if command -v git >/dev/null 2>&1; then
  if ! { git var GIT_AUTHOR_IDENT && git var GIT_COMMITTER_IDENT; } >/dev/null 2>&1; then
    printf "[WARN][agent-sandbox.nix] no git identity declared; git commit will fail. Set GIT_AUTHOR_*/GIT_COMMITTER_* in env, or bind a gitconfig (see README).\n" >&2
  fi
fi

exec "$@"
