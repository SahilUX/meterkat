"""Shared entity code: devices, unique IDs, and adding entities as providers appear."""

from __future__ import annotations

from collections.abc import Callable, Iterable
from typing import Any

from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers import device_registry as dr, entity_registry as er
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity import Entity
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import MeterkatConfigEntry, MeterkatCoordinator

# Unique IDs: "<entry>_<provider>_<window>_<key>" for window entities and
# "<entry>_<provider>_<key>" for provider entities. Provider IDs have no "_",
# and the key is always last, so window IDs may contain anything.
# Keys never contain "_": window IDs can, and the key is split off the end.
WINDOW_KEYS = ("used", "resets", "projected", "runsout")
PROVIDER_KEYS = ("problem", "status")


def entry_uid(entry: MeterkatConfigEntry) -> str:
    return entry.unique_id or entry.entry_id


def hub_device(entry: MeterkatConfigEntry, coordinator: MeterkatCoordinator) -> DeviceInfo:
    data = coordinator.data or {}
    return DeviceInfo(
        identifiers={(DOMAIN, entry_uid(entry))},
        name="Meterkat companion (%s)" % (data.get("host") or entry.unique_id),
        manufacturer="Meterkat",
        model="Companion",
        sw_version=data.get("companionVersion"),
    )


def async_register_hub(hass: HomeAssistant, entry: MeterkatConfigEntry) -> None:
    """Register the companion's device first, so provider devices can link to it."""
    device = dr.async_get(hass).async_get_or_create(
        config_entry_id=entry.entry_id, **hub_device(entry, entry.runtime_data)
    )
    entry.runtime_data.hub_device_id = device.id


def _via_hub(entry: MeterkatConfigEntry) -> dict[str, Any]:
    # Home Assistant 2026.8 links devices by device ID (via_device_id) and
    # deprecates the identifier form that older releases need.
    if "via_device_id" in DeviceInfo.__annotations__:
        return {"via_device_id": entry.runtime_data.hub_device_id}
    return {"via_device": (DOMAIN, entry_uid(entry))}


def wanted(provider: dict[str, Any]) -> bool:
    """Providers worth a device: signed in now, or with readings. A provider that
    was never signed in on the companion stays out instead of showing a problem
    forever; once it has entities they stay and report not_signed_in."""
    return provider.get("status") != "not_signed_in" or bool(provider.get("windows"))


def registered(hass: HomeAssistant, entry: MeterkatConfigEntry) -> tuple[set[str], set[tuple[str, str]]]:
    """Providers and (provider, window) pairs that already have entities."""
    prefix = entry_uid(entry) + "_"
    providers: set[str] = set()
    windows: set[tuple[str, str]] = set()
    for reg in er.async_entries_for_config_entry(er.async_get(hass), entry.entry_id):
        if not reg.unique_id.startswith(prefix):
            continue
        provider, _, rest = reg.unique_id[len(prefix):].partition("_")
        if rest in PROVIDER_KEYS:
            providers.add(provider)
        else:
            window, _, key = rest.rpartition("_")
            if window and key in WINDOW_KEYS:
                providers.add(provider)
                windows.add((provider, window))
    return providers, windows


def current(coordinator: MeterkatCoordinator) -> tuple[set[str], set[tuple[str, str]]]:
    providers: set[str] = set()
    windows: set[tuple[str, str]] = set()
    for provider in (coordinator.data or {}).get("providers", []):
        pid = provider.get("id")
        if not isinstance(pid, str) or not wanted(provider):
            continue
        providers.add(pid)
        windows.update((pid, w["id"]) for w in provider.get("windows") or [] if isinstance(w.get("id"), str))
    return providers, windows


def track_entities(
    hass: HomeAssistant,
    entry: MeterkatConfigEntry,
    async_add_entities: AddEntitiesCallback,
    for_provider: Callable[[str], Iterable[Entity]],
    for_window: Callable[[str, str], Iterable[Entity]],
) -> None:
    """Add entities for every known provider and window now, and for new ones
    as later snapshots bring them."""
    coordinator = entry.runtime_data
    seen_providers, seen_windows = registered(hass, entry)
    added_providers: set[str] = set()
    added_windows: set[tuple[str, str]] = set()

    @callback
    def add(providers: set[str], windows: set[tuple[str, str]]) -> None:
        new: list[Entity] = []
        for pid in sorted(providers - added_providers):
            new.extend(for_provider(pid))
        for pid, wid in sorted(windows - added_windows):
            new.extend(for_window(pid, wid))
        added_providers.update(providers)
        added_windows.update(windows)
        if new:
            async_add_entities(new)

    now_providers, now_windows = current(coordinator)
    add(seen_providers | now_providers, seen_windows | now_windows)
    entry.async_on_unload(coordinator.async_add_listener(lambda: add(*current(coordinator))))


class MeterkatEntity(CoordinatorEntity[MeterkatCoordinator]):
    _attr_has_entity_name = True

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str, key: str) -> None:
        super().__init__(coordinator)
        self.provider_id = provider_id
        entry = coordinator.config_entry
        uid = entry_uid(entry)
        self._attr_unique_id = "%s_%s_%s" % (uid, provider_id, key)
        provider = coordinator.provider(provider_id) or {}
        plan = provider.get("plan")
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, "%s_%s" % (uid, provider_id))},
            name=provider.get("name") or provider_id.title(),
            manufacturer="Meterkat",
            model=("%s plan" % plan.title()) if isinstance(plan, str) and plan else None,
            **_via_hub(entry),
        )

    @property
    def provider(self) -> dict[str, Any] | None:
        return self.coordinator.provider(self.provider_id)
