import json
from typing import Literal

import pytest

from harness.nix_eval import nix_eval


@pytest.mark.parametrize(
    "browsers",
    [
        pytest.param([], id="empty list"),
        pytest.param(["chromium"], id="chromium"),
        pytest.param(["firefox"], id="firefox"),
        pytest.param(["chromium", "firefox"], id="both engines"),
    ],
)
def test_accepted(browsers: list[str]) -> None:
    result = nix_eval(allow_headless_browsers=browsers, allow_unix_sockets=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["allow_headless_browsers"] == browsers


def test_defaults_to_empty() -> None:
    result = nix_eval()
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["allow_headless_browsers"] == []


@pytest.mark.parametrize(
    "browsers",
    [pytest.param(True, id="true"), pytest.param(False, id="false")],
)
def test_non_list_is_rejected(browsers: bool) -> None:
    result = nix_eval(allow_headless_browsers=browsers)
    assert result.returncode != 0
    assert "allowHeadlessBrowsers must be a list of browser engines" in result.stderr


@pytest.mark.parametrize(
    "browsers",
    [pytest.param(["chrome"], id="unknown engine"), pytest.param([1], id="non-string entry")],
)
def test_unknown_entry_is_rejected(browsers: list[object]) -> None:
    result = nix_eval(allow_headless_browsers=browsers)
    assert result.returncode != 0
    assert "allowHeadlessBrowsers entries must each be one of" in result.stderr


def test_repeated_engine_is_rejected() -> None:
    result = nix_eval(allow_headless_browsers=["firefox", "firefox"])
    assert result.returncode != 0
    assert "must not repeat an engine" in result.stderr


def test_linux_requires_unix_sockets() -> None:
    result = nix_eval(platform="linux", allow_headless_browsers=["chromium"])
    assert result.returncode != 0
    assert "allowHeadlessBrowsers requires allowUnixSockets = true on Linux" in result.stderr


@pytest.mark.parametrize(
    ("platform", "allow_unix_sockets"),
    [
        pytest.param("linux", True, id="linux with unix sockets"),
        pytest.param("darwin", False, id="darwin without unix sockets"),
    ],
)
def test_unix_socket_requirement_is_linux_only(
    platform: Literal["linux", "darwin"], allow_unix_sockets: bool
) -> None:
    result = nix_eval(
        platform=platform,
        allow_headless_browsers=["chromium"],
        allow_unix_sockets=allow_unix_sockets,
    )
    assert result.returncode == 0, result.stderr
