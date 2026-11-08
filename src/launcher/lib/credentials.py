import base64
from typing import BinaryIO, Mapping, assert_never

from launcher.lib.build_spec import InjectedCredentialSpec
from launcher.lib.constants import ERROR_PREFIX


def read_secrets(stream: BinaryIO) -> dict[str, str]:
    secrets: dict[str, str] = {}
    for entry in stream.read().split(b"\0"):
        if not entry:
            continue
        name, _, value = entry.decode("utf-8").partition("=")
        secrets[name] = value
    return secrets


def build_proxy_credentials(
    injected_credentials: Mapping[str, InjectedCredentialSpec],
    secrets: Mapping[str, str],
) -> dict[str, dict[str, str]]:
    credentials: dict[str, dict[str, str]] = {}
    for name, credential in injected_credentials.items():
        if name not in secrets:
            raise SystemExit(f"{ERROR_PREFIX} no secret was received for {name}")
        secret = secrets[name]
        for host, entry in credential.hosts.items():
            match entry.scheme:
                case "bearer":
                    header = "Authorization"
                    value = f"Bearer {secret}"
                case "basic":
                    pair = f"{entry.username}:{secret}".encode("utf-8")
                    header = "Authorization"
                    value = f"Basic {base64.b64encode(pair).decode('ascii')}"
                case "header":
                    assert entry.header is not None
                    header = entry.header
                    value = secret
                case _:
                    assert_never(entry.scheme)
            credentials[host] = {"header": header, "value": value}
    return credentials
