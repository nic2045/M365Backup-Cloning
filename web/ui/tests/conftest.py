"""Every test starts without sign-in settings from the environment (issue #60)."""

import os

import pytest


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in list(os.environ):
        if name.startswith(("M365_UI_", "M365CLONING_")):
            monkeypatch.delenv(name, raising=False)
