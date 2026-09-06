# agent-sandbox.nix

Declarative sandboxing for AI agents on Linux and macOS.

Stop your agents in YOLO mode from deleting your $HOME, force pushing to main, or publishing your ssh keys on reddit. The sandbox works with any CLI-based AI agent. The repository provides templates for common agent CLIs.

The sandbox uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux and sandbox-exec on macOS.

See [Security](#security) for the threat model and the known limits.

## What the sandbox allows

- **Project directory**: read/write access to the directory you launch the agent from.
- **Declared state**: read/write access to anything you list in `rwDirs` / `rwFiles`, or read-only access through `roDirs` / `roFiles`.
- **Allowed packages**: the binaries you list in `allowedPackages` are on the agent's PATH, together with `bash` and `cacert`.
- **Network filtering**: open by default. Optionally filtered to `allowedDomains`.
- **Environment**: environment restricted to declared environment variables.
- **Git**: git commands, including when launched within a worktree.
- **Nix**: disabled by default. You can let the agent run nix commands.

Everything else is denied. Only changes to the launch directory and declared rwDirs/files are persisted - the agent's home directory and anything else it writes are discarded upon exit.

## Contents

<!-- vim-markdown-toc GFM -->

* [Usage and configuration](#usage-and-configuration)
    * [Templates](#templates)
    * [Agent notes](#agent-notes)
    * [Arguments](#arguments)
    * [Network restrictions](#network-restrictions)
        * [Domain and internet access](#domain-and-internet-access)
        * [Host ports](#host-ports)
        * [Published ports](#published-ports)
    * [UNIX-domain sockets](#unix-domain-sockets)
* [Authentication](#authentication)
    * [Environment variable tokens (recommended)](#environment-variable-tokens-recommended)
    * [Credential files via `rwDirs`](#credential-files-via-rwdirs)
* [Git](#git)
    * [Setting your git identity](#setting-your-git-identity)
    * [What the sandbox exposes](#what-the-sandbox-exposes)
    * [Remote access (push / pull / fetch)](#remote-access-push--pull--fetch)
    * [Read-only paths in the git directory](#read-only-paths-in-the-git-directory)
* [Using Nix inside the sandbox](#using-nix-inside-the-sandbox)
* [Troubleshooting](#troubleshooting)
    * [Session directories](#session-directories)
    * [Probe the sandbox interactively](#probe-the-sandbox-interactively)
    * [Deriving a network allowlist](#deriving-a-network-allowlist)
    * [macOS: system denial log](#macos-system-denial-log)
    * [macOS: gh and other Go tools](#macos-gh-and-other-go-tools)
* [Security](#security)
    * [What it protects against](#what-it-protects-against)
    * [What it doesn't protect against](#what-it-doesnt-protect-against)
    * [Linux vs macOS](#linux-vs-macos)
    * [Is this the right tool for me?](#is-this-the-right-tool-for-me)
* [Limitations](#limitations)
* [Similar projects](#similar-projects)

<!-- vim-markdown-toc -->

## Usage and configuration

To get started quickly, use a flake template. If you do not use flakes, [`shells/claude.shell.nix`](shells/claude.shell.nix) is the same setup written as a plain `shell.nix`. The rest of [`shells/`](shells/) holds worked examples for narrower setups, linked from the sections they illustrate.

### Templates

The following flake templates are provided for quick setup:

| Template | Agent | Wrapped binary |
| --- | --- | --- |
| `claude` | Claude Code | `claude-sandboxed` |
| `codex` | Codex | `codex-sandboxed` |
| `copilot` | GitHub Copilot CLI | `copilot-sandboxed` |
| `gemini` | Gemini | `gemini-sandboxed` |
| `opencode` | OpenCode | `opencode-sandboxed` |
| `pi` | Pi | `pi-sandboxed` |

To initialize a template in your project directory:

```bash
nix flake init -t github:archie-judd/agent-sandbox.nix#<template>
```

The command creates a `flake.nix` in your project. Edit the file for your needs, and export your access token. Then enter the dev shell and run your wrapped binary:

```bash
nix develop
claude-sandboxed
```

To keep the original command name as the alias, change the `outName` value, for example to `"claude"`.

If your preferred agent does not have a template, please adapt one to your needs and consider contributing it to the repository!

1. Copy the closest template.
1. Adjust `pkg`, `binName`, `outName`, `allowedDomains` and the `rwDirs` the agent needs for its config and cache.
1. Register it under `templates` in [`flake.nix`](flake.nix).
1. Open a pull request.

### Agent notes

Most agents need nothing beyond their template. This table details agent-specific gotchas.

| Agent | Note |
| --- | --- |
| Codex | Codex sandboxes itself, and the two sandboxes cannot nest. Run `codex-sandboxed -s danger-full-access` and let this sandbox do the work. Without it, every command fails with `Failed to create unified exec process: Operation not permitted`. |
| OpenCode | Authenticates with `ANTHROPIC_API_KEY` from console.anthropic.com. A `CLAUDE_CODE_OAUTH_TOKEN` will not work: it is scoped to Claude Code, and a Claude subscription does not include API credit. |

The sandbox is tested with Claude Code, Codex, GitHub Copilot CLI and OpenCode. The Gemini and Pi templates are provided but untested.

### Arguments

`mkSandbox`, the library's entrypoint, accepts the following arguments:

| Argument | Required | Description |
|---|---|---|
| `pkg` | yes | Package that contains the binary to wrap |
| `binName` | yes | Name of the binary inside `pkg/bin/` |
| `outName` | yes | Name of the wrapped binary, and the command that runs it |
| `allowedPackages` | yes | Packages whose `bin/` dirs form the sandbox PATH. See the note below the table |
| `rwDirs` | no | Directories the agent can read and write (for example `~/.config/claude`, or a package manager's cache: see [`shells/claude-uv.shell.nix`](shells/claude-uv.shell.nix)) |
| `rwFiles` | no | Individual files the agent can read and write |
| `roDirs` | no | Directories the agent can read but not write (for example signed binaries, reference source trees, secret stores) |
| `roFiles` | no | Individual files the agent can read but not write (for example `~/.config/git/config` for the git identity, see [Setting your git identity](#setting-your-git-identity) |
| `env` | no | Additional environment variables, as an attrset |
| `allowedDomains` | no | Limits the domains the sandbox can reach. Leave it unset for open internet. Accepts a list of domains (all methods allowed), or an attrset that maps each domain to `"*"` or to a list of HTTP methods. `[ ]` blocks all internet access. |
| `allowUnixSockets` | no | If `true`, the agent can create and connect to UNIX-domain (AF_UNIX) sockets. It can connect in directories it can read, and bind in directories it can write. Defaults to `false`. See [UNIX-domain sockets](#unix-domain-sockets). |
| `allowedHostPorts` | no | Host-local TCP ports the sandbox can reach. Defaults to `[ ]`. Set it to `null` to allow all host-local TCP ports. Otherwise, entries must be integers from `1` to `65535`. |
| `publishedPorts` | no | Host TCP ports forwarded INTO the sandbox, so services the agent runs are reachable from outside. Defaults to `[ ]`. Entries are an integer port (bound to `127.0.0.1`) or `{ port = <int>; bindAddr = "<ipv4>"; }`. There is no `null` form. See [Published ports](#published-ports). |
| `allowNix` | no | If `true`, the sandbox exposes the host's `nix-daemon` socket and the full Nix store. The agent can then run `nix build`, `nix run`, `nix develop`, and similar commands. The sandbox adds `pkgs.nix` to PATH. Requires `allowUnixSockets = true`. Defaults to `false`. See [Using Nix inside the sandbox](#using-nix-inside-the-sandbox). |

The library also exports `commonTools`, a list of standard CLI tools. See [`default.nix`](default.nix) for the full list.

A minimal example. The arguments are the same for a flake and for a `shell.nix`:

```nix
mkSandbox {
  pkg = pkgs.claude-code;
  binName = "claude";
  outName = "claude-sandboxed";
  allowedPackages = commonTools; # or e.g. commonTools ++ [ pkgs.nodejs ]
  rwDirs = [ "$HOME/.claude" ];
  roFiles = [ "$HOME/.config/git/config" ];
  env = {
    CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
    CLAUDE_CONFIG_DIR = "$HOME/.claude";
  };
  allowedDomains = {
    "anthropic.com" = "*";
    "claude.com" = "*";
    "github.com" = ["GET" "HEAD"];
    "githubusercontent.com" = ["GET" "HEAD"];
  };
}
```

<details>
<summary><strong>Why set <code>CLAUDE_CONFIG_DIR</code> and not add <code>~/.claude.json</code> as a <code>rwFile</code>?</strong></summary>
<br>

The example sets `CLAUDE_CONFIG_DIR` to `$HOME/.claude`, so that Claude writes `~/.claude.json` inside the read/write `rwDir`. If you add `~/.claude.json` as a `rwFile` instead, Claude writes temporary files to the ephemeral home root when it updates its configuration. Claude then tries to rename these files to `~/.claude.json`. The rename can fail, or behave in an unexpected way, because the temporary files land outside every declared `rwDir` and `rwFile`. This can sometimes corrupt the `~/.claude.json` file.
<br>
<br>

> **Note:** If you also run Claude outside the sandbox, set `CLAUDE_CONFIG_DIR=$HOME/.claude` globally too. Otherwise the two use different config locations and diverge.

</details>

### Network restrictions

The sandbox controls network access with three independent settings. `allowedDomains` controls outbound internet access. `allowedHostPorts` controls access to host-local TCP services, such as databases and dev servers. `publishedPorts` controls which sandbox-hosted TCP services are reachable from outside.

By default, internet access is open, all host-local services are blocked, and nothing inside the sandbox is reachable from outside.

#### Domain and internet access

To restrict internet access, set `allowedDomains`. The sandbox can then reach only the domains you list. Leave it unset for open internet, or set it to `[ ]` to block all internet access.

`allowedDomains` accepts two formats:

- Attrset (recommended): map each domain to `"*"` (all HTTP methods allowed) or to a list of permitted methods (for example `[ "GET" "HEAD" ]`).
- List: `[ "anthropic.com" "sentry.io" ]`. This allows all methods for each domain.

The sandbox matches domains by suffix, so `"anthropic.com"` also matches all `*.anthropic.com` subdomains. The key `"*"` allows all domains, so to route everything through the proxy, and allow everything, use: `{ "*" = "*"; }`. This is useful for [deriving a network allowlist](deriving-a-network-allowlist), but it is not a restriction.

When you set `allowedDomains`, the sandbox routes all HTTP and HTTPS traffic through a filtering proxy. WebSocket connections are permitted only to a domain whose policy is `"*"`.

The proxy logs each allowed or denied host contact to `proxy.log` in the sandbox's [session directory](#session-directories). Only the first allow is logged to reduce noise.

#### Host ports

Host-local services (databases, dev servers, the SSH agent, the Docker socket, and similar) are blocked by default. Use `allowedHostPorts` to permit access to specific ports:

```nix
allowedHostPorts = [ 3000 5432 ];
```

Set `allowedHostPorts = null;` to allow all host-local TCP ports.

For a worked example, see [`shells/opencode-ollama.shell.nix`](shells/opencode-ollama.shell.nix), where the agent has no internet access at all and reaches only Ollama running on the host.

On macOS, a service started inside the sandbox also needs its port listed here, because `sandbox-exec` shares localhost with the host and cannot tell the two apart. See [Linux vs macOS](#linux-vs-macos).

#### Published ports

Sometimes something outside the sandbox must call INTO it. For example, an integration-test suite that hosts a callback server needs this, and so does a dev server you want to open in the host browser. Declare the ports with `publishedPorts`:

```nix
publishedPorts = [
  3000                                      # host 127.0.0.1:3000 → sandbox :3000
  { port = 8000; bindAddr = "0.0.0.0"; }    # reachable from anything that can reach the host
];
```

The default `bindAddr` is `127.0.0.1` which is reachable from host processes only. A wider address exposes whatever the agent runs on that port to everything that can reach that address. Use the narrowest `bindAddr` that serves the caller.

For a worked example, see [`shells/claude-docker.shell.nix`](shells/claude-docker.shell.nix), where a docker container on the host reaches a dev server running in the sandbox.

### UNIX-domain sockets

UNIX-domain sockets are denied by default, because a sandboxed process could use host sockets to reach your SSH agent or other per-user services. Set `allowUnixSockets = true` to permit them. Build tools that communicate over a domain socket (sbt/BSP, metals, nailgun) need this setting.

Socket access then follows the filesystem grants on both platforms. In paths the agent can write (the launch directory and `rwDirs`), the agent can create sockets and connect to them. In read-only paths (`roDirs`, `roFiles`, and the repository root when you launch from a subdirectory), the agent can only connect.

`allowNix = true` requires `allowUnixSockets = true`, because the agent reaches the nix daemon over a UNIX-domain socket.

## Authentication

The sandbox masks `$HOME`, so agents cannot reach your system keychain, browser sessions, or SSH keys. A launch from your home directory is the exception, and exposes all of it. The recommended method is to authenticate with an environment variable. Interactive login flows (for example `claude /login` and `gh auth login`) may not work inside the sandbox.

### Environment variable tokens (recommended)

Export your token in the host terminal before you launch the sandbox. The sandbox reads tokens at runtime, so they do not leak into the Nix store:

```
# Claude Code
export CLAUDE_CODE_OAUTH_TOKEN="<your_token_here>"

# GitHub Copilot CLI
export GITHUB_TOKEN="<your_token_here>"
```

Pass the variable reference, not the value, into `env`:

```nix
env = {
  CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
  ...
};
```

If you store your secret in a file instead (for example with sops), you can set a command that reads the secret at runtime:

```nix
env = {
  CLAUDE_CODE_OAUTH_TOKEN = "$(${pkgs.coreutils}/bin/cat /run/secrets/claude-code-oauth-token)";
  ...
};
```

### Credential files via `rwDirs`

If your agent stores credentials in files (Claude Code uses `~/.claude/`), run the login flow outside the sandbox first. Then expose the credential directory with `rwDirs`. The sandboxed agent reads the cached credentials.

<details>
<summary><strong>On macOS you will need to export the credentials from the Keychain first</strong></summary>

On macOS, Claude Code stores credentials in the system Keychain, not in files. The sandbox cannot read the Keychain, so the environment variable method above is the simplest option.

If you cannot use an environment variable token, you can export the Keychain credentials to a file that the sandbox can read:

```bash
# Log in outside the sandbox first
claude /login
```

```bash
# Then export credentials from Keychain to a file the sandbox can read
security dump-keychain 2>&1 \
  | grep -o 'Claude Code-credentials[^"]*' \
  | sort -u \
  | while read entry; do
      security find-generic-password -a "$USER" -s "$entry" -w 2>/dev/null
    done \
  | python3 -c "
import sys, json
most_recent = None
for line in sys.stdin:
    try:
        creds = json.loads(line.strip())
        exp = creds.get('claudeAiOauth', {}).get('expiresAt', 0)
        if most_recent is None or exp > most_recent[1]:
            most_recent = (line.strip(), exp)
    except: pass
if most_recent: print(most_recent[0])
" > ~/.claude/.credentials.json
```

This finds all Claude Code credential entries in the Keychain and exports the entry with the most recent expiry.

Then expose `~/.claude` with `rwDirs`. The sandboxed agent reads credentials from `~/.claude/.credentials.json` when it cannot reach the Keychain.

Note: OAuth access tokens expire. Run the export command again from time to time to refresh the credentials file.

</details>

## Git

Local git operations work with no extra configuration. The agent can switch branches, read history, and commit. A commit needs a declared git identity.

### Setting your git identity

The sandbox masks `$HOME`, so git cannot read your global gitconfig, and `user.name` and `user.email` are unset. If you declare no identity, `git commit` fails loudly (`fatal: ... auto-detection is disabled`).

You can declare a git identity in one of two ways:

- **Bind your host gitconfig read-only with `roFiles`** (recommended). Set your identity on the host (`git config --global user.name "..."; git config --global user.email "..."`), then add:

  ```nix
      roFiles = [ "$HOME/.config/git/config" ];  # or "$HOME/.gitconfig"
  ```

- **With `env`** (to set a custom identity, or if you cannot bind a host file):

  ```nix
      env = {
        GIT_AUTHOR_NAME = "Your Name";
        GIT_AUTHOR_EMAIL = "you@example.com";
        GIT_COMMITTER_NAME = "Your Name";
        GIT_COMMITTER_EMAIL = "you@example.com";
      };
  ```

### What the sandbox exposes

If there is a repo, the sandbox exposes these paths:

| Path | Access |
|---|---|
| The launch directory | read-write |
| The root .git directory | read-write, except the [read-only paths](#read-only-paths-in-the-git-directory) |
| The working tree root | read-only, and only when it is not the launch directory |

The working tree root is the root of the tree you launched in. It is not the root of the repo above it:

- **Worktrees:** the working tree root is the worktree itself. The sandbox does not expose the main checkout, or any sibling worktree.
- **Submodules:** the working tree root is the submodule itself. The sandbox does not expose the superproject working tree, or the git directory of any other submodule.

When launched in a subdirectory of the working tree, readonly access to the whole worktree is required to let git report on files above the launch directory. Without it, `git status` and `git diff` report those files as deleted.

### Remote access (push / pull / fetch)

Remote operations need authentication. Use HTTPS remotes rather than SSH remotes. The simplest method to authenticate HTTPS operations is to provide the `GITHUB_TOKEN` environment variable. You can also configure a [git credential helper](https://git-scm.com/doc/credential-helpers) that stores your token for reuse, so that you do not need to pass it through an environment variable.

SSH remotes (for example `git@github.com:...`) do not work by default. The sandbox masks `$HOME`, so the agent cannot read your SSH keys. When you set `allowedDomains`, the proxy handles only HTTP and HTTPS, so it blocks all SSH traffic. To use SSH remotes, expose your SSH directory with `rwDirs` (for example `$HOME/.ssh`), and leave `allowedDomains` unset for open network access. This is not recommended.

### Read-only paths in the git directory

Some paths inside the git directory are read-only inside the sandbox: `hooks/`, `config`, `config.worktree`, and the pointer files that record the location of a worktree's or a submodule's git directory. This is a security measure. See [Security](#what-it-protects-against).

All other paths stay writable, so commits, fetches, branch switches and history reads work as normal. Two operations do not work:

- `git config` cannot write to the repo config. Set repo-level config on the host instead.
- `git worktree remove` and `git worktree prune` fail, because the protected pointer file makes the worktree directory impossible to remove. Run these commands on the host.

## Using Nix inside the sandbox

Set `allowNix = true` to let the agent run nix commands inside the sandbox. The sandbox gives the agent access to the host's nix daemon and the full nix store. `pkgs.nix` is added to the agent's PATH, so you do not put it in `allowedPackages`. The agent reaches the daemon over a UNIX-domain socket, so `allowNix = true` requires `allowUnixSockets = true`. See [UNIX-domain sockets](#unix-domain-sockets).

What you need to configure:

- **Flake CLI features:** the sandbox does not expose your nix config. Bind it with `roFiles = [ "/etc/nix/nix.conf" ]` to inherit your whole config. Alternatively, set `env.NIX_CONFIG = "experimental-features = nix-command flakes"` to enable only the flake CLI.

- **Nix state directories:** the client caches the flake registry and downloaded tarballs in `$HOME/.cache/nix`. It writes registry overrides to `$HOME/.config/nix`. It stores per-user profiles in `$HOME/.local/share/nix`. Add these directories to `rwDirs` if you want that state to persist between launches.

- **Allowed domains:** when you set `allowedDomains`, the nix client itself needs `channels.nixos.org`, `github.com`, `raw.githubusercontent.com`, and `cache.nixos.org` to fetch packages and flakes reliably.

A complete example is at [`shells/claude-nix.shell.nix`](shells/claude-nix.shell.nix).

> **Security note:** `allowNix = true` weakens the security posture of the sandbox. The full Nix store is exposed, and the agent can run any executable in it. `allowedPackages` then limits only what is on `PATH`, not what the agent can execute. The `nix-daemon` runs outside the sandbox, so its own network activity does not obey `allowedDomains`. This activity includes downloads of prebuilt packages from the caches in the daemon's configuration.

## Troubleshooting

If you have a problem, or you think the agent cannot access a file or folder that the defaults should permit, please raise an issue. The most useful attachment is the session directory described below.

### Session directories

Every launch writes a directory that records what it did. The location is `$XDG_STATE_HOME/agent-sandbox`, or `~/.local/state/agent-sandbox` if `$XDG_STATE_HOME` is unset. The name of each directory is `<timestamp>-<pid>-<outName>`, so the newest is last:

```bash
ls -t ~/.local/state/agent-sandbox | head
```

Read `launch.log` first. It records:

- the version of agent-sandbox.nix that built the wrapper
- the configuration the wrapper received
- the expansion of your declared paths on this machine
- all warnings
- the exit status of the sandbox

The other files hold the configuration that the launch was assembled from, so they also show what was allowed:

| File | Platform | What it holds |
|---|---|---|
| `launch.log` | both | What was requested, what was decided, how it ended |
| `proxy.log` | both | The filtering proxy's output: the hosts it allowed, and everything it blocked |
| `seatbelt.sb` | macOS | The seatbelt profile that `sandbox-exec` enforced |
| `bwrap.args` | Linux | The bubblewrap arguments, including every bind |
| `network.json` | Linux | The firewall rules and the routing applied to the sandbox |

The sandbox keeps the directories of the newest 25 launches, and prunes the others at the next launch. It never prunes the directory of a session whose sandbox still runs, whatever its age.

To watch the proxy reject domains as they happen:

```bash
tail -f "$(ls -dt ~/.local/state/agent-sandbox/* | head -1)/proxy.log"
```

A session directory holds no secrets, so it is safe to attach to an issue.

### Probe the sandbox interactively

`launch.log` records what the sandbox was configured to allow. To see what a process actually hits, wrap `bash` itself with the same config as your agent, and explore. [`debug/bash.shell.nix`](debug/bash.shell.nix) is a template you can use directly. Copy your agent's `rwDirs`, `rwFiles`, `allowedPackages`, and `allowedDomains` into it, then run `nix-shell debug/bash.shell.nix`.

The shell has exactly the same filesystem view and the same restrictions as your agent. Try these:

```bash
ls $HOME/.claude                  # should work if in rwDirs (symlinked)
cat ~/.ssh/id_ed25519             # should fail: undeclared files in $HOME are not readable
which git                         # allowedPackages should be on PATH
curl https://example.com          # should fail if not in allowedDomains
```

If a path the agent needs is blocked, add it to `rwDirs` or `rwFiles`, or to `roDirs` or `roFiles` for read-only access.

### Deriving a network allowlist

The proxy logs all of the domains it allows or blocks, so you can build an allowlist from a real session rather than by guesswork. Watch the log while you use the agent:

```bash
tail -f "$(ls -dt ~/.local/state/agent-sandbox/* | head -1)/proxy.log"
```

The quickest way to see the whole picture is to allow all domains:

```nix
allowedDomains = { "*" = "*"; };
```

The agent works normally, and the log names each host on first contact. Replace the `"*"` entry with what you saw, then run again and confirm nothing is blocked.

Keep the methods as narrow as the agent allows. Use `[ "GET" "HEAD" ]` for anything it only reads from. An agent that uses WebSockets (Codex does) needs `"*"` for that domain.

### macOS: system denial log

`launch.log` and `seatbelt.sb` show the profile that `sandbox-exec` enforced, not which rule a process tripped. For that, query the system log after a failure:

```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```

Nothing in the session directory records this, so pair the log with `seatbelt.sb` when something your config should allow is blocked.

### macOS: gh and other Go tools

On macOS, when you set `allowedDomains`, `gh` (the GitHub CLI) fails HTTPS requests with a certificate error. The filtering proxy uses its own certificate. `git` accepts this certificate, but `gh` and other Go tools reject it on macOS. Linux is unaffected. The workaround is to use curl instead - most agents will figure this out themselves.

## Security

This section describes what the sandbox protects against, and what it does not protect against, so that you can decide whether it fits your situation. It assumes that you launch the agent from a project directory. A launch from `$HOME` turns off home masking entirely, and the sandbox asks for your permission first.

### What it protects against

The agent can do something it should not do. It can run a bad prompt, process a malicious file, use a compromised dependency, or invent a destructive command. In each case, the sandbox keeps the damage inside the project directory. In detail:

- The agent cannot read your SSH keys, browser sessions, password manager, the source code of other projects, or anything else in your home directory outside the paths you expose explicitly.
- The agent cannot delete or modify files outside the project directory and your declared `rwDirs` and `rwFiles`.
- The agent cannot reach internet domains outside the ones you allow, when you set `allowedDomains`.
- The agent cannot talk to local services on your laptop (databases, dev servers, the SSH agent, other terminal windows, and similar), unless you allow host-local TCP ports explicitly with `allowedHostPorts`.
- The agent cannot leave code behind that runs on your host at your next git command. A writable git directory would permit that: a file in `hooks/`, a `core.hooksPath` or `alias.*` entry in a config file, or a pointer file aimed at a git directory the agent controls. Those paths are read-only for the repo you launch in.
- The agent can run only the tools you list in `allowedPackages`, unless you set `allowNix = true`. See [Using Nix inside the sandbox](#using-nix-inside-the-sandbox).
- The agent cannot see your other running programs, read the environment variables they have set, or interfere with your other open terminals.
- The agent cannot widen its own sandbox by planting a symlink in a path you declared. See [Arguments](#arguments).

### What it doesn't protect against

The sandbox is an isolation boundary. It is not an anonymity boundary, and it is not a defense against an attacker who has already taken over your machine in some other way.

- The agent can fingerprint your machine. It can see your hostname, hardware model, CPU, RAM, OS version, and rough network details. If the agent must not know which machine it runs on, this is not the tool. Use a VM or a separate device.
- Your username and home directory path are visible to the agent. This is unavoidable, because the agent needs to know where `$HOME/.claude` resolves to. If your username is itself sensitive, this is not the right tool.
- All of `/nix/store` is readable, not only your allowed packages. The allowlist restricts execution only. The Nix store is normally world-readable on any system, so this matches existing behavior. It does mean that the agent can list every package you have built.
- A launch from a subdirectory does not limit reads to that subdirectory. The agent can read the whole working tree that contains it. See [What the sandbox exposes](#what-the-sandbox-exposes).
- The agent can read all of the git directory. This includes every branch, stash and reflog entry, also content that is no longer in the working tree.
- The agent has everything you hand it. If you expose your `~/.claude` directory (or any credential file) through `rwDirs`, or pass a token through `env`, the agent can read it. That is how it logs in. A compromised agent has the same access to those credentials as your shell. Treat this the way you would treat handing the token to any other CLI tool you did not write yourself.
- The agent can edit its own sandbox config. `flake.nix` lives inside the project directory, and the sandbox permits writes to it. An agent could weaken its own restrictions for the next session. The changes take effect only when you enter the dev shell again, so it is worth reading `git diff` first.
- The sandbox protects only the repo you launch in from git hook injection. It does not protect other repos that sit under your launch directory. A nested repo is writable like anything else there, and this includes its hooks.
- The sandbox is no defense against root access or kernel bugs. If something on your machine has already gained administrator-level access, or the operating system itself has a deeper bug, this sandbox cannot stop it.

### Linux vs macOS

Both platforms enforce the same default protections. The one practical difference is localhost. On Linux, bubblewrap gives the sandbox its own network namespace, so services started inside the sandbox can reach each other on any localhost port. On macOS, `sandbox-exec` shares localhost with the host. Localhost communication inside the sandbox therefore needs the port in `allowedHostPorts`, or all host-local ports allowed with `allowedHostPorts = null;`. The same access also opens those host-local ports.

### Is this the right tool for me?

If your threat model is *"I want my AI agent to not accidentally destroy my work, leak my private files, or talk to random places on the internet,"* this sandbox is a good fit.

If your threat model is *"I assume the agent is actively malicious and need it to be unable to identify my specific machine or my real user account,"* you want a VM with a throwaway user account, or a separate machine.

## Limitations

- `sandbox-exec` is deprecated on macOS. It remains the only native unprivileged sandboxing mechanism. It currently works on macOS 26 (Tahoe) and older, but a future release may break it.
- The sandbox is tested on x86_64-linux and aarch64-darwin. Other architectures should work, but they are untested.

## Similar projects

There are several other tools for sandboxing AI agents. Here are a few:

[Anthropic sandbox-runtime (srt)](https://github.com/anthropic-experimental/sandbox-runtime/tree/main): an npm package that also uses bubblewrap on Linux and sandbox-exec on macOS.

[jail.nix](https://git.sr.ht/~alexdavid/jail.nix): a nix library that builds bubblewrap sandboxes. It is not agent-specific, but you can use it to sandbox agents. Linux only.

[jailed-agents](https://github.com/andersonjoseph/jailed-agents): a nix library that provides pre-configured per-agent sandboxes with bubblewrap. Linux only.

[agent-box](https://github.com/fletchgqc/agentbox): a Rust CLI that uses disposable containers with Jujutsu or Git worktrees. macOS and Linux.

[ai-jail](https://github.com/akitaonrails/ai-jail): a Rust CLI that sandboxes agents with bubblewrap (with Landlock and seccomp) on Linux and sandbox-exec on macOS. It is configured with a TOML file in the project directory.
