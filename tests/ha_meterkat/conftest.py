"""Fixtures for the Meterkat Home Assistant integration tests."""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.meterkat.const import DOMAIN

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "usage.json").read_text())
HISTORY_FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "history.json").read_text())
HOST = "192.168.1.20"
PORT = 47300
URL = "http://%s:%d" % (HOST, PORT)
TOKEN = "mkd_ab12cd34_test-token-not-real"
SHARED_TOKEN = "shared-token-not-real"
USAGE_URL = URL + "/v1/usage"
HISTORY_URL = URL + "/v1/history"
HEALTH = {"ok": True, "version": "2.5.0", "pollSeconds": 120}
NOW = "2026-10-24T21:52:00+00:00"


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    yield


@pytest.fixture(autouse=True)
def frozen_time(freezer):
    freezer.move_to(NOW)
    return freezer


@pytest.fixture
def snapshot() -> dict[str, Any]:
    return copy.deepcopy(FIXTURE)


@pytest.fixture
def config_entry() -> MockConfigEntry:
    return MockConfigEntry(
        domain=DOMAIN,
        title="Meterkat (testbox)",
        unique_id="testbox",
        version=2,
        data={"url": URL, "token": TOKEN, "verify_ssl": True},
    )
