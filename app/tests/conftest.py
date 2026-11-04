import os
import sys

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    import main

    with TestClient(main.app) as c:
        yield c
