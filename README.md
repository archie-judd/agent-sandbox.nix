# agent-sandbox.nix

Lightweight and declarative sandboxing for AI agents on Linux and macOS.

Prevent your agents in YOLO mode from deleting your $HOME, force pushing to main, or publishing your ssh keys on reddit. The sandbox works with any CLI-based AI agent. It is tested with Claude Code and GitHub Copilot CLI (see [Supported agents](#supported-agents)).

The sandbox uses [bubblewrap](https://github.com/containers/bubblewrap) on Linux and sandbox-exec on macOS. See [Security](#security) for the threat model and the known limits.

## What the sandbox allows

- **Project directory**: read/write access to the directory you launch the agent from.
- **Declared state**: read/write access to anything you list in `rwDirs` / `rwFiles`, or read-only access through `roDirs` / `roFiles`.
- **Allowed packages**: the binaries you list in `allowedPackages` are on the agent's PATH, together with `bash` and `cacert`.
- **Network**: open internet access by default, with host-local services blocked. Set `allowedDomains` to limit the internet domains. Set `allowedLocalPorts` to permit specific host-local TCP ports.
- **Environment**: only the variables you pass through `env` reach the agent. The sandbox clears the rest of the host environment.
- **Git**: read/write access to the git directory, and read-only access to the directory that contains it. The same applies when the git directory is outside the project tree (worktrees). See [Git](#git).
- **Nix**: disabled by default. You can let the agent run nix commands.

The sandbox denies everything else. `$HOME` is an ephemeral writable tmpfs that disappears when the sandbox exits. There is one exception. If you launch the agent from your home directory, the sandbox exposes that directory read-write, like any other launch directory. See [Launching from your home directory](#launching-from-your-home-directory).

## Contents

<!-- vim-markdown-toc GFM -->

* [Usage and configuration](#usage-and-configuration)
    * [Templates](#templates)
    * [Arguments](#arguments)
    * [Network restrictions](#network-restrictions)
        * [Domain and internet access](#domain-and-internet-access)
        * [Host-local ports](#host-local-ports)
    * [UNIX-domain sockets](#unix-domain-sockets)
    * [Supported agents](#supported-agents)
* [Authentication](#authentication)
    * [Environment variable tokens (recommended)](#environment-variable-tokens-recommended)
    * [Credential files via `rwDirs`](#credential-files-via-rwdirs)
* [Git](#git)
    * [What the sandbox exposes](#what-the-sandbox-exposes)
    * [Remote access (push / pull / fetch)](#remote-access-push--pull--fetch)
    * [Git identity](#git-identity)
    * [Read-only paths in the git directory](#read-only-paths-in-the-git-directory)
* [Using Nix inside the sandbox](#using-nix-inside-the-sandbox)
* [Common patterns / recipes](#common-patterns--recipes)
    * [Python with uv](#python-with-uv)
    * [Node.js with npm](#nodejs-with-npm)
* [Troubleshooting](#troubleshooting)
    * [Session directories](#session-directories)
    * [Filesystem access issues](#filesystem-access-issues)
    * [Network access issues](#network-access-issues)
    * [macOS: unexpected sandbox denials](#macos-unexpected-sandbox-denials)
    * [macOS: localhost service denials](#macos-localhost-service-denials)
* [Security](#security)
    * [What it protects against](#what-it-protects-against)
    * [What it doesn't protect against](#what-it-doesnt-protect-against)
    * [Launching from your home directory](#launching-from-your-home-directory)
    * [Specific things worth being aware of](#specific-things-worth-being-aware-of)
    * [Linux vs macOS](#linux-vs-macos)
    * [Is this the right tool for me?](#is-this-the-right-tool-for-me)
* [Caveats](#caveats)
* [Similar projects](#similar-projects)

<!-- vim-markdown-toc -->

## Usage and configuration

The quickest way to start is with a flake template. If you prefer a `shell.nix`, see [`shells/`](shells/) for examples you can use directly. For authentication, see [Authentication](#authentication).

<details id="v0x-to-v1x-migration-guide">
<summary><strong>V0.x to V1.x migration guide</strong></summary>
<br>

V1.x renames some arguments and removes `restrictNetwork`. If you use an old name, you get an error that tells you the new name. Update your config as follows:

| Old | New |
|---|---|
| `extraEnv = { … }` | `env = { … }` |
| `stateDirs = [ … ]` | `rwDirs = [ … ]` |
| `stateFiles = [ … ]` | `rwFiles = [ … ]` |
| `restrictNetwork = true; allowedDomains = …` | `allowedDomains = …` |
| `restrictNetwork = true; allowedDomains = [ ]` | `allowedDomains = [ ]` |
| `restrictNetwork = false` | remove it, and do not set `allowedDomains` |

`allowedDomains` now controls network access on its own. Leave it unset for open internet. List the domains you want to allow. Set it to `[ ]` to block everything.

**If you relied on host loopback reachability:** in V0.x, an unset `restrictNetwork` let the agent reach host-local services (Ollama, a local database, a local MCP server, and similar). This no longer works by default. The sandbox blocks host loopback unless you permit ports with `allowedLocalPorts`.

</details>

### Templates

The repository provides flake templates for Claude Code and GitHub Copilot CLI for quick project setup. You can change either template to work with another CLI tool.

To initialize a template in your project directory:

```bash
nix flake init -t github:archie-judd/agent-sandbox.nix#claude
# or
nix flake init -t github:archie-judd/agent-sandbox.nix#copilot
```

This command creates a `flake.nix` in your project. See [`templates/claude/flake.nix`](templates/claude/flake.nix) for the contents. Edit the file for your needs, export your access token, and then enter the dev shell:

```bash
nix develop
```

Then run your wrapped binary:

```bash
claude-sandboxed --dangerously-skip-permissions # Claude Code's "YOLO mode"
# or
copilot-sandboxed --yolo
```

To keep the original command name as the alias, change the `outName` value, for example to `"claude"` or `"copilot"`.

### Arguments

`mkSandbox`, the library's entrypoint, accepts the following arguments:

| Argument | Required | Description |
|---|---|---|
| `pkg` | yes | Package that contains the binary to wrap |
| `binName` | yes | Name of the binary inside `pkg/bin/` |
| `outName` | yes | Name of the wrapped binary, and the command that runs it |
| `allowedPackages` | yes | Packages whose `bin/` dirs form the sandbox PATH. See the note below the table |
| `rwDirs` | no | Directories the agent can read and write (for example `~/.config/claude`) |
| `rwFiles` | no | Individual files the agent can read and write |
| `roDirs` | no | Directories the agent can read but not write (for example signed binaries, reference source trees, secret stores) |
| `roFiles` | no | Individual files the agent can read but not write (for example `~/.config/git/config` for the git identity, see [Git identity](#git-identity)) |
| `env` | no | Additional environment variables, as an attrset |
| `allowedDomains` | no | Limits the domains the sandbox can reach. Leave it unset for open internet. Accepts a list of domains (all methods allowed), or an attrset that maps each domain to `"*"` or to a list of HTTP methods. `[ ]` blocks all internet access. |
| `allowUnixSockets` | no | If `true`, the agent can create and connect to UNIX-domain (AF_UNIX) sockets. It can connect in directories it can read, and bind in directories it can write. Defaults to `false`. See [UNIX-domain sockets](#unix-domain-sockets). |
| `allowedLocalPorts` | no | Host-local TCP ports the sandbox can reach. Defaults to `[ ]`. Set it to `null` to allow all host-local TCP ports. Otherwise, entries must be integers from `1` to `65535`. |
| `allowNix` | no | If `true`, the sandbox exposes the host's `nix-daemon` socket and the full Nix store, so the agent can run `nix build`, `nix run`, `nix develop`, and similar commands. The sandbox adds `pkgs.nix` to PATH. Requires `allowUnixSockets = true`. Defaults to `false`. See [Using Nix inside the sandbox](#using-nix-inside-the-sandbox). |

The sandbox adds `bash` and `cacert` to `allowedPackages` by default. The sandbox needs a shell to run, and `cacert` is necessary for HTTPS. The library also exports `commonTools`, a list of standard CLI tools. See [`default.nix`](default.nix) for the full list.

Paths in `rwDirs`, `rwFiles`, `roDirs` and `roFiles` must exist on the host before launch. If a path is missing, the sandbox exits with an error.

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

The example sets `CLAUDE_CONFIG_DIR` to `$HOME/.claude` so that Claude writes `~/.claude.json` inside the read/write `rwDir`. If you add `~/.claude.json` as a `rwFile` instead, Claude writes temporary files to the ephemeral home root when it updates its configuration. Claude then tries to rename these files to `~/.claude.json`. The rename can fail or behave in an unexpected way, because the temporary files land outside every declared `rwDir` and `rwFile`. This can sometimes corrupt the `~/.claude.json` file.
<br>
<br>

> **Note:** If you also run Claude outside the sandbox, set `CLAUDE_CONFIG_DIR=$HOME/.claude` globally too. Otherwise the two use different config locations and diverge.

</details>

### Network restrictions

The sandbox controls network access with two independent settings. `allowedDomains` controls outbound internet access. `allowedLocalPorts` controls access to host-local TCP services, such as databases and dev servers. The two settings do not interact. An allowed domain never gives loopback access, and an allowed local port never gives internet access. By default, internet access is open and all host-local services are blocked.

#### Domain and internet access

To restrict internet access, set `allowedDomains`. The sandbox can then reach only the domains you list. Leave it unset for open internet, or set it to `[ ]` to block all internet access.

`allowedDomains` accepts two formats:

- Attrset (recommended): map each domain to `"*"` (all HTTP methods allowed) or to a list of permitted methods (for example `[ "GET" "HEAD" ]`).
- List: `[ "anthropic.com" "sentry.io" ]`. This allows all methods for each domain.

The sandbox matches domains by suffix, so `"anthropic.com"` also matches all `*.anthropic.com` subdomains.

When you set `allowedDomains`, the sandbox routes all HTTP and HTTPS traffic through a filtering proxy. The proxy inspects each request by domain and HTTP method. The sandbox cannot avoid the proxy, and DNS resolution is blocked. WebSocket connections are not permitted. The proxy records blocked requests in `proxy.log`, in the launch's [session directory](#session-directories).

Known limitations when the proxy is active:

- SSH-based git remotes: see [Git](#git).
- On macOS, `gh` and some other tools cannot connect through the proxy: see [Caveats](#caveats).

#### Host-local ports

Host-local services (databases, dev servers, the SSH agent, the Docker socket, and similar) are blocked by default. They stay blocked when you set `allowedDomains`. Use `allowedLocalPorts` to permit access to specific ports:

```nix
allowedLocalPorts = [ 3000 5432 ];
```

Set `allowedLocalPorts = null;` to allow all host-local TCP ports. Keep explicit port lists as short as possible. Broad access can expose host-local services.

### UNIX-domain sockets

UNIX-domain (AF_UNIX) sockets are denied by default, because a sandboxed process would use host sockets to reach your SSH agent or other per-user services. Set `allowUnixSockets = true` to permit them. Build tools that communicate over a domain socket (sbt/BSP, metals, nailgun) need this setting. Socket access then follows the filesystem grants on both platforms. In paths the agent can write (the launch directory and `rwDirs`), the agent can create sockets and connect to them. In read-only paths (`roDirs`, `roFiles`, and the repository root when you launch from a subdirectory), the agent can only connect.

`allowNix = true` requires `allowUnixSockets = true`, because the agent reaches the nix daemon over a UNIX-domain socket.

### Supported agents

The sandbox is tested with `claude-code` and `copilot-cli`. Other agents should work if they support token-based authentication through an environment variable. See [Authentication](#authentication).

## Authentication

The sandbox masks `$HOME`, so agents cannot reach your system keychain, browser sessions, or SSH keys. A launch from your home directory is the exception, and exposes all of it (see [Launching from your home directory](#launching-from-your-home-directory)). The recommended method is to authenticate with an environment variable. Interactive login flows (for example `claude /login` and `gh auth login`) may not work inside the sandbox.

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

If your agent stores credentials in files (Claude Code uses `~/.claude/`), run the login flow outside the sandbox first, then expose the credential directory with `rwDirs`. The sandboxed agent then reads the cached credentials.

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

Local git operations work with no extra configuration. The agent can switch branches, read history, and commit. A commit needs a declared git identity. See [Git identity](#git-identity).

### What the sandbox exposes

At launch, the sandbox asks git for the common git directory. Git searches upward from the launch directory to find it. If there is no repo, the sandbox exposes no git paths. If there is a repo, the sandbox exposes three paths:

| Path | Access |
|---|---|
| The launch directory | read-write |
| The git directory | read-write, except the [read-only paths](#read-only-paths-in-the-git-directory) |
| The parent of the git directory | read-only |

For an ordinary repo, that parent is the repo root. This is why git works when you launch from a subdirectory. Two cases are different:

- **Worktrees:** the git directory belongs to the main repo, so its parent is the main repo root. The agent can read the main checkout, and each sibling worktree below it.
- **Submodules:** the git directory is `<superproject>/.git/modules/<name>`, so its parent is `.git/modules`. The sandbox does not expose the superproject working tree. The agent can read the git directory of other submodules.

If that parent is your home directory or above it, the sandbox disables git for the session and prints a warning. A repo whose root is `$HOME` therefore gets no git support. The exception is a launch from `$HOME` itself.

### Remote access (push / pull / fetch)

Remote operations need authentication. Use HTTPS remotes rather than SSH remotes. The simplest method is to pass a token through `env`, for example `GITHUB_TOKEN`. You can also configure a [git credential helper](https://git-scm.com/doc/credential-helpers) that stores your token for reuse, so that you do not pass it through an environment variable.

SSH remotes (for example `git@github.com:...`) do not work by default. The sandbox masks `$HOME`, so the agent cannot read your SSH keys. When you set `allowedDomains`, the proxy handles only HTTP and HTTPS, so it blocks all SSH traffic. To use SSH remotes, expose your SSH directory with `rwDirs` (for example `$HOME/.ssh`) and leave `allowedDomains` unset for open network access. This is not recommended.

### Git identity

The sandbox masks `$HOME`, so git cannot read your global gitconfig, and `user.name` and `user.email` are unset. The sandbox never invents an identity. If you declare no identity, `git commit` fails loudly (`fatal: ... auto-detection is disabled`).

For correctly attributed commits, declare a real identity in one of two ways:

- **Bind your host gitconfig read-only with `roFiles`** (recommended). Set your identity on the host (`git config --global user.name "..."; git config --global user.email "..."`), then add:

  ```nix
      roFiles = [ "$HOME/.config/git/config" ];  # or "$HOME/.gitconfig"
  ```

  git reads `[user]` through its normal global-config lookup. The file is read-only inside the sandbox, so the agent cannot set `core.hooksPath`, `core.fsmonitor`, or `alias.*` entries. Such entries would run host code at your next host `git` command.

- **With `env`** (fully self-contained, useful when you cannot bind a host file):

  ```nix
      env = {
        GIT_AUTHOR_NAME = "Your Name";
        GIT_AUTHOR_EMAIL = "you@example.com";
        GIT_COMMITTER_NAME = "Your Name";
        GIT_COMMITTER_EMAIL = "you@example.com";
      };
  ```

> **Note:** do not run `git config --global ...` inside the sandbox. `$HOME` is an ephemeral tmpfs there, so the change does not persist. Set your identity on the host and bind it, or use `env`.

### Read-only paths in the git directory

Some paths inside the git directory are read-only inside the sandbox: `hooks/`, `config`, `config.worktree`, and the pointer files that record the location of a worktree's or a submodule's git directory. This is a security measure. See [Security](#what-it-protects-against).

All other paths stay writable, so commits, fetches, branch switches and history reads work as normal. Two operations do not work:

- `git config` cannot write to the repo config. Set repo-level config on the host instead.
- `git worktree remove` and `git worktree prune` fail, because the protected pointer file makes the worktree directory impossible to remove. Run these commands on the host.

## Using Nix inside the sandbox

Set `allowNix = true` to let the agent run nix commands inside the sandbox. The sandbox gives the agent access to the host's nix daemon and the full nix store. The sandbox adds `pkgs.nix` to the agent's PATH, so you do not put it in `allowedPackages`. The agent reaches the daemon over a UNIX-domain socket, so `allowNix = true` requires `allowUnixSockets = true`. See [UNIX-domain sockets](#unix-domain-sockets).

What you need to configure:

- **Flake CLI features:** the sandbox does not expose your nix config. Bind it with `roFiles = [ "/etc/nix/nix.conf" ]` to inherit your whole config, or set `env.NIX_CONFIG = "experimental-features = nix-command flakes"` to enable only the flake CLI.

- **Nix state directories:** the client caches the flake registry and downloaded tarballs in `$HOME/.cache/nix`. It writes registry overrides to `$HOME/.config/nix`. It stores per-user profiles in `$HOME/.local/share/nix`. Add these directories to `rwDirs` if you want that state to persist between launches.

- **Allowed domains:** when you set `allowedDomains`, the nix client itself needs `channels.nixos.org`, `github.com`, `raw.githubusercontent.com`, and `cache.nixos.org` to fetch packages and flakes reliably.

A complete example is at [`shells/claude-nix.shell.nix`](shells/claude-nix.shell.nix).

> **Security note:** `allowNix = true` weakens the security posture of the sandbox. The full Nix store is exposed, and the agent can run any executable in it. `allowedPackages` then limits only what is on `PATH`, not what the agent can execute. The `nix-daemon` runs outside the sandbox, so its own network activity does not obey `allowedDomains`. This activity includes downloads of prebuilt packages from the caches in the daemon's configuration.

## Common patterns / recipes

### Python with uv

uv needs access to its cache directories through `rwDirs`. Without them, uv downloads the dependencies again at every launch. On NixOS, pre-compiled wheels also fail to find glibc. To prevent this, pass `LD_LIBRARY_PATH` through from the host and use a nix-managed Python rather than a uv-managed one. See [`shells/claude-uv.shell.nix`](shells/claude-uv.shell.nix) for the full setup.

### Node.js with npm

For Node, add the npm cache as a `rwDir`.

```nix
allowedPackages = [ pkgs.nodejs pkgs.npm ];
rwDirs = [ "$HOME/.npm" ]; # Allow npm cache
```

## Troubleshooting

If you have a problem, or you think the agent cannot access a file or folder that the defaults should permit, please raise an issue. The most useful attachment is the session directory described below.

### Session directories

Every launch writes a directory that records what it did. The location is `$XDG_STATE_HOME/agent-sandbox`, or `~/.local/state/agent-sandbox` if `$XDG_STATE_HOME` is unset. The name of each directory is `<timestamp>-<pid>-<outName>`, so the newest is last:

```bash
ls -t ~/.local/state/agent-sandbox | head
```

Read `launch.log` first. It records the version of agent-sandbox.nix that built the wrapper, the configuration the wrapper received, the expansion of your declared paths on this machine, all warnings, and the exit status of the sandbox.

The other files hold the configuration that the launch was assembled from, so they also show what was allowed:

| File | Platform | What it holds |
|---|---|---|
| `launch.log` | both | What was requested, what was decided, how it ended |
| `proxy.log` | both | The filtering proxy's output, including blocked domains |
| `seatbelt.sb` | macOS | The seatbelt profile that `sandbox-exec` enforced |
| `bwrap.args` | Linux | The bubblewrap arguments, including every bind |
| `network.json` | Linux | The firewall rules and the routing applied to the sandbox |

The sandbox keeps the directories of the newest 25 launches and prunes the others at the next launch. It never prunes the directory of a session whose sandbox still runs, whatever its age.

A session directory holds no secrets, so it is safe to attach to an issue. The values from `env` never reach it. The launcher's shell resolves the values and passes them straight to the sandbox, and only the names are recorded.

### Filesystem access issues

If a tool call, a file read, or a file write fails, the sandbox probably blocks a path. Add the path to `rwDirs` or `rwFiles`, or to `roDirs` or `roFiles` for read-only access.

The easiest way to examine the sandbox environment is to wrap `bash` itself with the same config as your agent, and then explore it interactively.

```nix
# mirror your agent's config
bash-sandboxed = sandbox.mkSandbox {
  pkg = pkgs.bashInteractive;
  binName = "bash";
  outName = "bash-sandboxed";
  allowedPackages = [ pkgs.coreutils ];
  rwDirs = [ "$HOME/.claude" ];
  rwFiles = [];
  allowedDomains = { "httpbin.org" = "*"; };
};
```

`bash-sandboxed` starts a shell with exactly the same filesystem view and the same restrictions as your agent. Try these commands:

```bash
touch "$TMPDIR/test" && rm "$TMPDIR/test"   # $TMPDIR should be writable
curl https://example.com          # depends on your allowedDomains setting
which git                         # allowedPackages should be on PATH
ls /some/other/path               # should fail, confirming the sandbox is active
cat ~/.ssh/id_ed25519             # should fail: undeclared files in $HOME are not readable
ls $HOME                          # empty dir with symlinks to rwDirs
touch $HOME/.test && rm $HOME/.test  # writes allowed (but ephemeral)
ls $HOME/.claude                  # should work if in rwDirs (symlinked)
curl https://httpbin.org/get      # allowed domain: should work
curl https://example.com          # blocked domain: should fail
```

See [`debug/bash.shell.nix`](debug/bash.shell.nix) for a template you can use directly. It sets `allowedDomains` to `httpbin.org` for testing.

### Network access issues

If you set `allowedDomains` and requests fail, check which domains are blocked. The proxy's log is in the session directory for the run:

```bash
tail -f "$(ls -dt ~/.local/state/agent-sandbox/* | head -1)/proxy.log"
```

You may need to add those domains to `allowedDomains`.

On macOS, `gh` and other Go-based tools can fail with a certificate error rather than a blocked request. The tool rejects the filtering proxy's certificate, and the domain is not the problem. See [Caveats](#caveats).

### macOS: unexpected sandbox denials

After a failure, you can query the system log for sandbox denials:

```bash
log show --predicate 'eventMessage CONTAINS "deny"' --last 1m
```

If the sandbox blocks something that your config should allow, this log can show which path or operation `sandbox-exec` denied.

### macOS: localhost service denials

If a sandboxed process cannot reach another sandboxed process on `localhost:<port>`, add that port to `allowedLocalPorts`. You can also allow all host-local TCP ports with `allowedLocalPorts = null;`. This applies to macOS only. `sandbox-exec` shares localhost with the host, so it cannot tell sandbox-internal services apart from host-local ones. See [Linux vs macOS](#linux-vs-macos) for the full explanation. The same access also opens those host-local ports, so keep explicit lists narrow.

## Security

This section describes what the sandbox protects against, and what it does not protect against, so that you can decide whether it fits your situation.

### What it protects against

The agent can do something it should not do. It can run a bad prompt, process a malicious file, use a compromised dependency, or invent a destructive command. In each case, the sandbox keeps the damage inside the project directory. In detail:

- The agent cannot read your SSH keys, browser sessions, password manager, the source code of other projects, or anything else in your home directory outside the paths you expose explicitly. This assumes that you launch the agent from a project directory. A launch from your home directory exposes all of it, and the sandbox says so before it starts.
- The agent cannot delete or modify files outside the project directory and your declared `rwDirs` and `rwFiles`.
- The agent cannot reach internet domains outside the ones you allow, when you set `allowedDomains`.
- The agent cannot talk to local services on your laptop (databases, dev servers, the SSH agent, other terminal windows, and similar), unless you allow host-local TCP ports explicitly with `allowedLocalPorts`.
- The agent cannot leave code behind that runs on your host at your next git command. A writable git directory would permit that: a file in `hooks/`, a `core.hooksPath` or `alias.*` entry in a config file, or a pointer file aimed at a git directory the agent controls. Those paths are read-only for the repo you launch in.
- The agent can run only the tools you list in `allowedPackages`, unless you set `allowNix = true`. See [Using Nix inside the sandbox](#using-nix-inside-the-sandbox).
- The agent cannot see your other running programs, read the environment variables they have set, or interfere with your other open terminals.

### What it doesn't protect against

The sandbox is an isolation boundary. It is not an anonymity boundary, and it is not a defense against an attacker who has already taken over your machine in some other way.

- The agent can fingerprint your machine. It can see your hostname, hardware model, CPU, RAM, OS version, and rough network details. If the agent must not know which machine it runs on, this is not the tool. Use a VM or a separate device.
- The agent has everything you hand it. If you expose your `~/.claude` directory (or any credential file) through `rwDirs`, or pass a token through `env`, the agent can read it. That is how it logs in. A compromised agent has the same access to those credentials as your shell. Treat this the way you would treat handing the token to any other CLI tool you did not write yourself.
- The agent can edit its own sandbox config. `flake.nix` lives inside the project directory, and the sandbox permits writes to it. An agent could weaken its own restrictions for the next session. The changes take effect only when you enter the dev shell again, so it is worth reading `git diff` first.
- The sandbox protects only the repo you launch in from git hook injection. It does not protect other repos that sit under your launch directory. A nested repo is writable like anything else there, and this includes its hooks.
- The sandbox is no defense against root access or kernel bugs. If something on your machine has already gained administrator-level access, or the operating system itself has a deeper bug, this sandbox cannot stop it.

### Launching from your home directory

The launch directory is always read-write. A launch from `$HOME` therefore gives the agent your whole home directory: ssh keys, credential files, browser state, and every other project. None of the masking described above applies in that session.

The `.git` directory of every repo under your home is then writable, and the sandbox protects only the repo you launch in from hook injection. A write to the hooks or the config of any other repo runs code on your host at your next git command there.

The sandbox allows this, because it follows from what the launch directory means, but it asks for your permission first.

The sandbox refuses a launch directory above `$HOME` (`/`, `/home`, `/Users`) outright. Those paths reach past your own home, and no confirmation covers that.

### Specific things worth being aware of

- A launch from `$HOME` turns off home masking entirely. See [Launching from your home directory](#launching-from-your-home-directory). Everything below assumes that you launch from a project directory.
- Your username and home directory path are visible to the agent. This is unavoidable, because the agent needs to know where `$HOME/.claude` resolves to. If your username is itself sensitive, this is not the right tool.
- All of `/nix/store` is readable, not only your allowed packages. The allowlist restricts execution only. The Nix store is normally world-readable on any system, so this matches existing behavior, but it does mean that the agent can list every package you have built.
- A launch from a subdirectory does not limit reads to that subdirectory. The agent can read the whole repo. From a worktree, it can also read the main checkout. See [What the sandbox exposes](#what-the-sandbox-exposes).
- The agent can read all of the git directory. This includes every branch, stash and reflog entry, also content that is no longer in the working tree.

### Linux vs macOS

Both platforms enforce the same default protections. The one practical difference is localhost. On Linux, bubblewrap gives the sandbox its own network namespace, so services started inside the sandbox can reach each other freely on any localhost port. On macOS, `sandbox-exec` shares localhost with the host. Localhost communication inside the sandbox therefore needs the port in `allowedLocalPorts`, or all host-local ports allowed with `allowedLocalPorts = null;`. The same access also opens those host-local ports.

### Is this the right tool for me?

If your threat model is *"I want my AI agent to not accidentally destroy my work, leak my private files, or talk to random places on the internet,"* this sandbox is a good fit.

If your threat model is *"I assume the agent is actively malicious and need it to be unable to identify my specific machine or my real user account,"* you want a VM with a throwaway user account, or a separate machine.

## Caveats

- `sandbox-exec` is deprecated on macOS. It remains the only native unprivileged sandboxing mechanism, and it currently works on macOS 26 (Tahoe) and older, but a future release may break it.
- The sandbox follows a symlink inside `rwDirs`, `rwFiles`, `roDirs`, or `roFiles` only to an already-permitted path. A symlink is usable only if its target is the Nix store, the working directory, the Git directory, or another declared bind. Everything else is blocked. This prevents an agent from planting a symlink during a session to expand its own sandbox at the next startup (for example `~/.claude/evil -> /etc/shadow`). To expose a path that is not permitted and that a symlink currently reaches, declare the path explicitly as a `rwDir`, `rwFile`, `roDir`, or `roFile`. A symlink into the Nix store is read-only.
- On macOS, when you set `allowedDomains`, `gh` (the GitHub CLI) fails HTTPS requests with a certificate error. The filtering proxy uses its own certificate. `git` accepts this certificate, but `gh` and other Go tools reject it on macOS. Linux is unaffected.
- Tested on x86_64-linux and aarch64-darwin. Other architectures should work, but they are untested.

## Similar projects

There are several other tools for sandboxing AI agents. Here are a few:

[Anthropic sandbox-runtime (srt)](https://github.com/anthropic-experimental/sandbox-runtime/tree/main): an npm package that also uses bubblewrap on Linux and sandbox-exec on macOS.

[jail.nix](https://git.sr.ht/~alexdavid/jail.nix): a nix library that builds bubblewrap sandboxes. It is not agent-specific, but you can use it to sandbox agents. Linux only.

[jailed-agents](https://github.com/andersonjoseph/jailed-agents): a nix library that provides pre-configured per-agent sandboxes with bubblewrap. Linux only.

[agent-box](https://github.com/fletchgqc/agentbox): a Rust CLI that uses disposable containers with Jujutsu or Git worktrees. macOS and Linux.

[ai-jail](https://github.com/akitaonrails/ai-jail): a Rust CLI that sandboxes agents with bubblewrap (with Landlock and seccomp) on Linux and sandbox-exec on macOS. It is configured with a TOML file in the project directory.
