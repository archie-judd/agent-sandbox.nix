import json
import platform as host_platform
import subprocess
import sys
from pathlib import Path
from typing import Literal

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent

_ARCHITECTURES = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}

_EXPRESSION = f"""
{{ argsJson, system }}:
let
  pkgs = import {_REPO_ROOT}/tests/pinned-nixpkgs.nix {{ system = system; }};
  sandbox = import {_REPO_ROOT}/default.nix {{ pkgs = pkgs; }};
  wrapper = sandbox.mkSandbox (
    {{
      pkg = pkgs.bashInteractive;
      binName = "bash";
      outName = "eval";
      allowedPackages = [ pkgs.coreutils ];
    }}
    // builtins.fromJSON argsJson
  );
in
builtins.fromJSON (builtins.unsafeDiscardStringContext wrapper.buildSpec.text)
"""


class _Omitted:
    pass


_OMITTED = _Omitted()


def _system(platform: Literal["linux", "darwin"] | None) -> str:
    os_name = sys.platform if platform is None else platform
    if os_name == "darwin":
        return "aarch64-darwin"
    return f"{_ARCHITECTURES[host_platform.machine()]}-{os_name}"


def nix_eval(
    *,
    platform: Literal["linux", "darwin"] | None = None,
    allow_nix: object = _OMITTED,
    allow_unix_sockets: object = _OMITTED,
    allow_headless_browsers: object = _OMITTED,
    allowed_domains: object = _OMITTED,
    allowed_host_ports: object = _OMITTED,
    published_ports: object = _OMITTED,
    workspace_dir: object = _OMITTED,
    proxy_redirects: object = _OMITTED,
    extra_env: object = _OMITTED,
    state_dirs: object = _OMITTED,
    state_files: object = _OMITTED,
    restrict_network: object = _OMITTED,
    allowed_local_ports: object = _OMITTED,
) -> subprocess.CompletedProcess[str]:
    args = {
        "allowNix": allow_nix,
        "allowUnixSockets": allow_unix_sockets,
        "allowHeadlessBrowsers": allow_headless_browsers,
        "allowedDomains": allowed_domains,
        "allowedHostPorts": allowed_host_ports,
        "publishedPorts": published_ports,
        "workspaceDir": workspace_dir,
        "_proxyRedirects": proxy_redirects,
        "extraEnv": extra_env,
        "stateDirs": state_dirs,
        "stateFiles": state_files,
        "restrictNetwork": restrict_network,
        "allowedLocalPorts": allowed_local_ports,
    }
    passed = {name: value for name, value in args.items() if value is not _OMITTED}
    return subprocess.run(
        [
            "nix-instantiate",
            "--eval",
            "--strict",
            "--json",
            "--argstr",
            "argsJson",
            json.dumps(passed),
            "--argstr",
            "system",
            _system(platform),
            "-E",
            _EXPRESSION,
        ],
        capture_output=True,
        text=True,
    )
