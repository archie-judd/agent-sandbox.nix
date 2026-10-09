import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Iterator
from pathlib import Path
from typing import Mapping

import pytest

from harness.build import BuildSandbox, nix_build_sandbox
from harness.launch import Launch, launch_sandbox


@pytest.fixture(scope="session")
def build_sandbox(tmp_path_factory: pytest.TempPathFactory) -> BuildSandbox:
    out_links = tmp_path_factory.mktemp("builds")
    built: dict[str, Path] = {}

    def build(fixture: str, args: Mapping[str, object] | None = None) -> Path:
        resolved_args = {} if args is None else args
        key = json.dumps([fixture, resolved_args], sort_keys=True)
        if key not in built:
            out_link = out_links / f"result-{len(built)}"
            built[key] = nix_build_sandbox(fixture, resolved_args, out_link=out_link)
        return built[key]

    return build


@pytest.fixture
def fake_home(tmp_path: Path) -> Path:
    home = tmp_path / "home"
    home.mkdir()
    return home


@pytest.fixture
def sessions_root(tmp_path: Path) -> Path:
    root = tmp_path / "sessions"
    root.mkdir()
    return root


@pytest.fixture
def launch(tmp_path: Path, fake_home: Path, sessions_root: Path) -> Launch:
    def run(
        binary: Path,
        script: str,
        *,
        cwd: Path | None = None,
        home: Path | None = None,
        env: Mapping[str, str] | None = None,
        tty_reply: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if cwd is None:
            cwd = tmp_path / "workspace"
            cwd.mkdir(exist_ok=True)
        return launch_sandbox(
            binary,
            script,
            cwd=cwd,
            home=fake_home if home is None else home,
            sessions_root=sessions_root,
            env={} if env is None else env,
            tty_reply=tty_reply,
        )

    return run


@pytest.fixture
def basic_sandbox(build_sandbox: BuildSandbox, fake_home: Path) -> Path:
    (fake_home / ".test-state-dir").mkdir()
    (fake_home / ".test-state-file").touch()
    return build_sandbox("basic-sandbox")


@pytest.fixture
def short_tmp() -> Iterator[Path]:
    directory = Path(os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sbx.")))
    yield directory
    shutil.rmtree(directory, ignore_errors=True)
