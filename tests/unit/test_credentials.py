import io

import pytest

from launcher.lib.build_spec import CredentialHostSpec, InjectedCredentialSpec
from launcher.lib.credentials import build_proxy_credentials, read_secrets


def test_secrets_are_read_from_nul_separated_entries() -> None:
    stream = io.BytesIO(b"GH_TOKEN=real\0OTHER=a=b c\0")

    assert read_secrets(stream) == {"GH_TOKEN": "real", "OTHER": "a=b c"}


def test_empty_input_reads_no_secrets() -> None:
    assert read_secrets(io.BytesIO(b"")) == {}


def test_each_scheme_builds_its_header() -> None:
    injected = {
        "GH_TOKEN": InjectedCredentialSpec(
            placeholder="dummy",
            hosts={
                "api.github.com": CredentialHostSpec(scheme="bearer", username=None, header=None),
                "github.com": CredentialHostSpec(
                    scheme="basic", username="x-access-token", header=None
                ),
            },
        ),
        "GITLAB_TOKEN": InjectedCredentialSpec(
            placeholder="dummy",
            hosts={
                "gitlab.test": CredentialHostSpec(
                    scheme="header", username=None, header="PRIVATE-TOKEN"
                ),
            },
        ),
    }

    credentials = build_proxy_credentials(injected, {"GH_TOKEN": "real", "GITLAB_TOKEN": "glpat"})

    assert credentials == {
        "api.github.com": {"header": "Authorization", "value": "Bearer real"},
        "github.com": {"header": "Authorization", "value": "Basic eC1hY2Nlc3MtdG9rZW46cmVhbA=="},
        "gitlab.test": {"header": "PRIVATE-TOKEN", "value": "glpat"},
    }


def test_a_missing_secret_is_refused() -> None:
    injected = {
        "GH_TOKEN": InjectedCredentialSpec(
            placeholder="dummy",
            hosts={"api.github.com": CredentialHostSpec(scheme="bearer", username=None, header=None)},
        ),
    }

    with pytest.raises(SystemExit, match="no secret was received for GH_TOKEN"):
        build_proxy_credentials(injected, {})
