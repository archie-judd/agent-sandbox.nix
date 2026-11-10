import json
from typing import Any

import pytest

from harness.nix_eval import nix_eval


def _credential(**hosts: dict[str, str]) -> dict[str, Any]:
    return {"secret": "$SECRET", "placeholder": "dummy", "hosts": hosts}


def test_accepted_credentials_reach_the_spec_without_the_secret() -> None:
    result = nix_eval(
        allowed_domains=["github.com", "gitlab.test/api"],
        injected_credentials={
            "GH_TOKEN": {
                "secret": "$SECRET",
                "placeholder": "dummy",
                "hosts": {
                    "api.github.com": {"scheme": "bearer"},
                    "github.com": {"scheme": "basic", "username": "x-access-token"},
                },
            },
            "GITLAB_TOKEN": {
                "secret": "$OTHER",
                "placeholder": "dummy",
                "hosts": {"gitlab.test": {"scheme": "header", "header": "PRIVATE-TOKEN"}},
            },
        },
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["injected_credentials"] == {
        "GH_TOKEN": {
            "placeholder": "dummy",
            "hosts": {
                "api.github.com": {"scheme": "bearer", "username": None, "header": None},
                "github.com": {"scheme": "basic", "username": "x-access-token", "header": None},
            },
        },
        "GITLAB_TOKEN": {
            "placeholder": "dummy",
            "hosts": {
                "gitlab.test": {"scheme": "header", "username": None, "header": "PRIVATE-TOKEN"},
            },
        },
    }


def test_wildcard_domain_allows_any_host() -> None:
    result = nix_eval(
        allowed_domains={"*": "*"},
        injected_credentials={"TOKEN": _credential(**{"api.example.test": {"scheme": "bearer"}})},
    )

    assert result.returncode == 0, result.stderr


def test_unrestricted_network_is_rejected() -> None:
    result = nix_eval(
        injected_credentials={"TOKEN": _credential(**{"api.example.test": {"scheme": "bearer"}})},
    )

    assert result.returncode != 0
    assert "injectedCredentials requires allowedDomains" in result.stderr


def test_a_name_that_is_not_an_env_var_is_rejected() -> None:
    result = nix_eval(
        allowed_domains=["example.test"],
        injected_credentials={"NOT-A-NAME": _credential(**{"example.test": {"scheme": "bearer"}})},
    )

    assert result.returncode != 0
    assert 'injectedCredentials names must be env var names. Invalid: ["NOT-A-NAME"]' in result.stderr


@pytest.mark.parametrize(
    "entry",
    [
        pytest.param({"placeholder": "dummy", "hosts": {"example.test": {"scheme": "bearer"}}}, id="no secret"),
        pytest.param({"secret": "$SECRET", "hosts": {"example.test": {"scheme": "bearer"}}}, id="no placeholder"),
        pytest.param(_credential(**{"example.test": {"scheme": "bearer"}}) | {"placeholder": ""}, id="empty placeholder"),
        pytest.param(_credential(), id="no hosts"),
        pytest.param(_credential(**{"example.test": {"scheme": "digest"}}), id="unknown scheme"),
        pytest.param(_credential(**{"example.test": {"scheme": "basic"}}), id="basic without username"),
        pytest.param(_credential(**{"example.test": {"scheme": "header"}}), id="header without header"),
        pytest.param(
            _credential(**{"example.test": {"scheme": "bearer", "username": "x"}}), id="bearer with username"
        ),
        pytest.param(_credential(**{"example.test": {"scheme": "basic", "username": ""}}), id="empty username"),
        pytest.param(_credential(**{"example.test": {"scheme": "bearer"}}) | {"extra": "x"}, id="unknown field"),
    ],
)
def test_an_invalid_entry_is_rejected(entry: dict[str, Any]) -> None:
    result = nix_eval(allowed_domains=["example.test"], injected_credentials={"TOKEN": entry})

    assert result.returncode != 0
    assert 'injectedCredentials entries must be { secret = <string>;' in result.stderr
    assert 'Invalid: ["TOKEN"]' in result.stderr


def test_a_name_also_set_in_env_is_rejected() -> None:
    result = nix_eval(
        allowed_domains=["example.test"],
        env={"TOKEN": "x"},
        injected_credentials={"TOKEN": _credential(**{"example.test": {"scheme": "bearer"}})},
    )

    assert result.returncode != 0
    assert 'injectedCredentials names must not also be set in env. Both: ["TOKEN"]' in result.stderr


def test_a_host_in_two_credentials_is_rejected() -> None:
    result = nix_eval(
        allowed_domains=["example.test"],
        injected_credentials={
            "ONE": _credential(**{"example.test": {"scheme": "bearer"}}),
            "TWO": _credential(**{"Example.test": {"scheme": "bearer"}}),
        },
    )

    assert result.returncode != 0
    assert (
        'injectedCredentials must not name a host in more than one credential. Repeated: ["example.test"]'
        in result.stderr
    )


@pytest.mark.parametrize(
    "host",
    [
        pytest.param("other.test", id="unlisted host"),
        pytest.param("notexample.test", id="shared suffix"),
    ],
)
def test_a_host_not_allowed_by_allowed_domains_is_rejected(host: str) -> None:
    result = nix_eval(
        allowed_domains=["example.test"],
        injected_credentials={"TOKEN": _credential(**{host: {"scheme": "bearer"}})},
    )

    assert result.returncode != 0
    assert f'injectedCredentials hosts must be allowed by allowedDomains. Not allowed: ["{host}"]' in result.stderr
