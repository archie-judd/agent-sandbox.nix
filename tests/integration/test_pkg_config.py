from pathlib import Path

from harness.build import BuildSandbox
from harness.launch import Launch

SCRIPT = """
[ -n "$PKG_CONFIG_PATH" ] && echo path-set
pkg-config --exists libffi && echo lib-pkgconfig
pkg-config --exists zlib && echo share-pkgconfig
[ "$(pkg-config --modversion sandbox-share-only)" = "1.0" ] && echo share-only
for package in libffi zlib; do
  include=$(pkg-config --cflags-only-I "$package") && include=${include#-I} \
    && [ -n "$include" ] && [ -d "$include" ] && echo "include-$package"
done
lib_dirs=readable
for flag in $(pkg-config --libs-only-L zlib); do [ -d "${flag#-L}" ] || lib_dirs=missing; done
[ "$lib_dirs" = readable ] && echo lib-dir
pkg-config --cflags --libs libffi zlib >/dev/null && echo flags
pkg-config --exists openssl || echo no-openssl
"""


def test_pkg_config_sees_exactly_the_allowed_packages(
    build_sandbox: BuildSandbox, launch: Launch, tmp_path: Path
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "openssl.pc").write_text("Name: openssl\nDescription: decoy\nVersion: 1.0\n")

    result = launch(
        build_sandbox("pkg-config"), SCRIPT, cwd=workspace, env={"PKG_CONFIG_PATH": str(workspace)}
    )

    assert result.stdout.split() == [
        "path-set",
        "lib-pkgconfig",
        "share-pkgconfig",
        "share-only",
        "include-libffi",
        "include-zlib",
        "lib-dir",
        "flags",
        "no-openssl",
    ], result.stderr
