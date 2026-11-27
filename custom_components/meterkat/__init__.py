"""The Meterkat integration: AI plan usage from a Meterkat companion."""

from __future__ import annotations

import ssl as ssl_lib
from functools import partial
from typing import Any

from homeassistant.const import CONF_HOST, CONF_PORT, CONF_TOKEN, Platform
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryNotReady
from homeassistant.helpers import issue_registry as ir
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .api import MeterkatClient, SslOption, supports_device_tokens, url_from_host_port
from .const import (
    CONF_CA_FILE,
    CONF_URL,
    CONF_VERIFY_SSL,
    DEVICE_TOKEN_PREFIX,
    DOMAIN,
    LOGGER,
)
from .coordinator import MeterkatConfigEntry, MeterkatCoordinator
from .entity import async_register_hub

PLATFORMS = [Platform.BINARY_SENSOR, Platform.SENSOR]


async def async_ssl_option(hass: HomeAssistant, data: dict[str, Any]) -> SslOption:
    """How to verify the companion's certificate: the system CAs, a custom CA file, or not at all."""
    if not data.get(CONF_VERIFY_SSL, True):
        return False
    if ca_file := data.get(CONF_CA_FILE):
        return await hass.async_add_executor_job(partial(ssl_lib.create_default_context, cafile=ca_file))
    return True


async def async_setup_entry(hass: HomeAssistant, entry: MeterkatConfigEntry) -> bool:
    try:
        ssl = await async_ssl_option(hass, entry.data)
    except (OSError, ssl_lib.SSLError) as err:
        raise ConfigEntryNotReady("Cannot load the CA file %s: %s" % (entry.data.get(CONF_CA_FILE), err)) from err
    client = MeterkatClient(async_get_clientsession(hass), entry.data[CONF_URL], entry.data[CONF_TOKEN], ssl)
    coordinator = MeterkatCoordinator(hass, entry, client)
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator
    async_register_hub(hass, entry)
    _update_shared_token_issue(hass, entry, coordinator)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_create_background_task(hass, coordinator.async_watch(), "meterkat long-poll")
    entry.async_on_unload(entry.add_update_listener(_async_options_updated))
    return True


def _update_shared_token_issue(hass: HomeAssistant, entry: MeterkatConfigEntry, coordinator: MeterkatCoordinator) -> None:
    """Point out that this entry still uses the companion's shared token, when the companion can do better."""
    issue_id = "shared_token_%s" % entry.entry_id
    version = (coordinator.data or {}).get("companionVersion")
    if not entry.data[CONF_TOKEN].startswith(DEVICE_TOKEN_PREFIX) and supports_device_tokens(version):
        ir.async_create_issue(
            hass, DOMAIN, issue_id, is_fixable=False, severity=ir.IssueSeverity.WARNING,
            translation_key="shared_token", translation_placeholders={"name": entry.title},
            learn_more_url="https://github.com/SahilUX/meterkat/blob/main/companion/README.md#paired-devices",
        )
    else:
        ir.async_delete_issue(hass, DOMAIN, issue_id)


async def async_unload_entry(hass: HomeAssistant, entry: MeterkatConfigEntry) -> bool:
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def async_remove_entry(hass: HomeAssistant, entry: MeterkatConfigEntry) -> None:
    ir.async_delete_issue(hass, DOMAIN, "shared_token_%s" % entry.entry_id)


async def _async_options_updated(hass: HomeAssistant, entry: MeterkatConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_migrate_entry(hass: HomeAssistant, entry: MeterkatConfigEntry) -> bool:
    """Version 1 entries stored host and port; version 2 stores the companion's URL."""
    if entry.version > 2:
        return False
    if entry.version == 1:
        data = dict(entry.data)
        if CONF_URL not in data:
            data[CONF_URL] = url_from_host_port(data.pop(CONF_HOST), data.pop(CONF_PORT))
        data.setdefault(CONF_VERIFY_SSL, True)
        hass.config_entries.async_update_entry(entry, data=data, version=2)
        LOGGER.debug("Migrated Meterkat entry %s to version 2", entry.entry_id)
    return True
