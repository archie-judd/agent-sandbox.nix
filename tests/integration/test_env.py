from pathlib import Path

from harness.build import BuildSandbox
from harness.launch import Launch


def test_every_unresolvable_value_is_reported_by_attribute(
    build_sandbox: BuildSandbox, launch: Launch, sessions_root: Path
) -> None:
    binary = build_sandbox("env-unresolved")

    result = launch(binary, "true", env={"SANDBOX_TEST_RESOLVED": "resolved-value"})

    assert result.returncode == 1
    assert "[ERROR][agent-sandbox.nix] could not resolve these env values:" in result.stderr
    assert 'ENV_MISSING_ONE = "$SANDBOX_TEST_MISSING_ONE"' in result.stderr
    assert 'ENV_MISSING_TWO = "$SANDBOX_TEST_MISSING_TWO"' in result.stderr
    assert "unbound variable" not in result.stderr
    assert "sandboxed-bash-env" not in result.stderr
    assert list(sessions_root.iterdir()) == []


def test_resolved_values_arrive_with_quoting_intact(
    build_sandbox: BuildSandbox, launch: Launch
) -> None:
    binary = build_sandbox("env-unresolved")

    result = launch(
        binary,
        'printf "%s|%s|%s" "$ENV_RESOLVED" "$ENV_SPACED" "$ENV_MISSING_ONE"',
        env={
            "SANDBOX_TEST_RESOLVED": "resolved-value",
            "SANDBOX_TEST_MISSING_ONE": "one",
            "SANDBOX_TEST_MISSING_TWO": "two",
        },
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "resolved-value|a b  c|one"
