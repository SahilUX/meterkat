"""Diagnostics for Meterkat, with the token and account names redacted."""

from __future__ import annotations

from typing import Any

from homeassistant.components.diagnostics import async_redact_data
from homeassistant.const import CONF_TOKEN
from homeassistant.core import HomeAssistant

from .coordinator import MeterkatConfigEntry

TO_REDACT = {CONF_TOKEN, "account", "email"}


async def async_get_config_entry_diagnostics(hass: HomeAssistant, entry: MeterkatConfigEntry) -> dict[str, Any]:
    coordinator = entry.runtime_data
    return {
        "entry": {
            "data": async_redact_data(dict(entry.data), TO_REDACT),
            "options": dict(entry.options),
        },
        "last_update_success": coordinator.last_update_success,
        "snapshot": async_redact_data(coordinator.data or {}, TO_REDACT),
    }
