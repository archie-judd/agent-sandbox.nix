# shellcheck shell=bash
# pre-entry-script — the first process inside the sandbox, ahead of the agent
# binary. It runs after the env (including the injected user.useConfigOnly and
# any user-declared GIT_AUTHOR_*/GIT_COMMITTER_*) is applied and with cwd set to
# the workspace, so the probe below reflects the true in-sandbox git state.
#
# Purpose: warn the *user* — at launch, on their terminal, before the agent
# runs — when no git identity is declared, since the commit-time failure is
# otherwise only loud to the agent (which can self-heal by inventing one). The
# sandbox itself never fabricates an identity: with useConfigOnly set, git's
# gecos/hostname auto-detection is disabled, so `git commit` fails closed.
#
# This is advisory only, never a gate — an identity-less session stays fully
# usable for non-committing work. The probe no-ops cleanly when git is not on
# PATH. `git var` of both idents (exit 0 only when identity resolves via any
# channel: env, bound config, or repo-local config) also catches a partial
# declaration. After probing, exec the real command unchanged.
if command -v git >/dev/null 2>&1; then
  if ! { git var GIT_AUTHOR_IDENT && git var GIT_COMMITTER_IDENT; } >/dev/null 2>&1; then
    printf "[WARN][agent-sandbox.nix] no git identity declared; git commit will fail. Set GIT_AUTHOR_*/GIT_COMMITTER_* in env, or bind a gitconfig — see the README.\n\n" >&2
  fi
fi

exec "$@"
