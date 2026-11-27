"""Problem sensor per provider: error, not signed in, stale, or companion unreachable."""

from __future__ import annotations

from typing import Any

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .coordinator import MeterkatConfigEntry, MeterkatCoordinator, provider_problems
from .entity import MeterkatEntity, track_entities


async def async_setup_entry(
    hass: HomeAssistant, entry: MeterkatConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    coordinator = entry.runtime_data
    track_entities(hass, entry, async_add_entities, lambda pid: [ProblemSensor(coordinator, pid)], lambda p, w: [])


class ProblemSensor(MeterkatEntity, BinarySensorEntity):
    """Stays available when the companion is unreachable, and turns on, so a
    dashboard shows the outage instead of a grey tile."""

    _attr_translation_key = "problem"
    _attr_device_class = BinarySensorDeviceClass.PROBLEM

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str) -> None:
        super().__init__(coordinator, provider_id, "problem")

    @property
    def available(self) -> bool:
        return self.coordinator.data is not None

    def _reasons(self) -> list[str]:
        if not self.coordinator.last_update_success:
            return ["companion_unreachable"]
        provider = self.provider
        if provider is None:
            return ["missing"]
        return provider_problems(provider)

    @property
    def is_on(self) -> bool:
        return bool(self._reasons())

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        provider = self.provider or {}
        return {
            "reasons": self._reasons(),
            "status": provider.get("status"),
            "error": provider.get("error"),
            "fetched_at": provider.get("fetchedAt"),
        }
