import sys

import pytest


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    for item in items:
        for platform in ("linux", "darwin"):
            if item.get_closest_marker(platform) and sys.platform != platform:
                item.add_marker(pytest.mark.skip(reason=f"{platform} only"))
