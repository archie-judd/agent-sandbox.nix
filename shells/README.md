# Example shells

Worked `shell.nix` examples for [agent-sandbox.nix](../README.md). Run one with
`nix-shell shells/<file>`, or copy it into your project and adjust it.

| Shell | Demonstrates |
| --- | --- |
| [`claude.shell.nix`](claude.shell.nix) | The `claude` template written as a plain `shell.nix`, for projects that do not use flakes |
| [`claude-docker.shell.nix`](claude-docker.shell.nix) | `publishedPorts`: a docker container on the host drives a dev server the agent runs |
| [`claude-nix.shell.nix`](claude-nix.shell.nix) | `allowNix` and `allowUnixSockets`: letting the agent run nix inside the sandbox |
| [`claude-uv.shell.nix`](claude-uv.shell.nix) | uv and Python: the cache directories and library paths uv needs |
| [`opencode-ollama.shell.nix`](opencode-ollama.shell.nix) | `allowedHostPorts` with no internet access: the agent reaches only Ollama on the host |

Each file imports the published library from GitHub, so it works when copied
out of this repository.
