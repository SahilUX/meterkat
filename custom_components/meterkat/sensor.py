"""Usage, reset time and status sensors for Meterkat."""

from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Any

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity, SensorStateClass
from homeassistant.const import PERCENTAGE, EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import STATUSES
from .coordinator import MeterkatConfigEntry, MeterkatCoordinator, parse_time
from .entity import MeterkatEntity, entry_uid, hub_device, track_entities


async def async_setup_entry(
    hass: HomeAssistant, entry: MeterkatConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    coordinator = entry.runtime_data
    async_add_entities([SnapshotSensor(coordinator)])
    track_entities(
        hass,
        entry,
        async_add_entities,
        lambda pid: [StatusSensor(coordinator, pid)],
        lambda pid, wid: [
            UsedSensor(coordinator, pid, wid),
            ResetsSensor(coordinator, pid, wid),
            ProjectedSensor(coordinator, pid, wid),
            RunsOutSensor(coordinator, pid, wid),
        ],
    )


def reset_time(window: dict[str, Any]) -> datetime | None:
    """resetsAt rounded to the minute. Providers report the same reset a second
    apart from one fetch to the next (16:59:59, then 17:00:00), which would
    otherwise log a change with every snapshot."""
    value = parse_time(window.get("resetsAt"))
    if value is None:
        return None
    return (value + timedelta(seconds=30)).replace(second=0, microsecond=0)


class SnapshotSensor(CoordinatorEntity[MeterkatCoordinator], SensorEntity):
    """When the companion built the current snapshot."""

    _attr_has_entity_name = True
    _attr_translation_key = "snapshot"
    _attr_device_class = SensorDeviceClass.TIMESTAMP
    _attr_entity_category = EntityCategory.DIAGNOSTIC

    def __init__(self, coordinator: MeterkatCoordinator) -> None:
        super().__init__(coordinator)
        entry = coordinator.config_entry
        self._attr_unique_id = "%s_snapshot" % entry_uid(entry)
        self._attr_device_info = hub_device(entry, coordinator)

    @property
    def native_value(self) -> datetime | None:
        return parse_time((self.coordinator.data or {}).get("generatedAt"))


class StatusSensor(MeterkatEntity, SensorEntity):
    _attr_translation_key = "status"
    _attr_device_class = SensorDeviceClass.ENUM
    _attr_options = STATUSES

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str) -> None:
        super().__init__(coordinator, provider_id, "status")

    @property
    def available(self) -> bool:
        return super().available and self.provider is not None

    @property
    def native_value(self) -> str | None:
        status = (self.provider or {}).get("status")
        return status if status in STATUSES else None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        provider = self.provider or {}
        return {
            "plan": provider.get("plan"),
            "error": provider.get("error"),
            "stale": bool(provider.get("stale")),
            "fetched_at": provider.get("fetchedAt"),
        }


class WindowEntity(MeterkatEntity):
    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str, window_id: str, key: str) -> None:
        super().__init__(coordinator, provider_id, "%s_%s" % (window_id, key))
        self.window_id = window_id
        label = (coordinator.window(provider_id, window_id) or {}).get("label") or window_id
        self._attr_translation_placeholders = {"window": label}

    @property
    def window(self) -> dict[str, Any] | None:
        return self.coordinator.window(self.provider_id, self.window_id)

    @property
    def available(self) -> bool:
        return super().available and self.window is not None


class UsedSensor(WindowEntity, SensorEntity):
    """Percent of the window's limit used, 0-100."""

    _attr_translation_key = "used"
    _attr_native_unit_of_measurement = PERCENTAGE
    _attr_state_class = SensorStateClass.MEASUREMENT
    _attr_suggested_display_precision = 0

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str, window_id: str) -> None:
        super().__init__(coordinator, provider_id, window_id, "used")

    @property
    def native_value(self) -> float | None:
        percent = (self.window or {}).get("percent")
        return float(percent) if isinstance(percent, (int, float)) else None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        window = self.window or {}
        percent = self.native_value
        return {
            "label": window.get("label"),
            "kind": window.get("kind"),
            "window_id": self.window_id,
            "remaining": round(max(0.0, 100 - percent), 1) if percent is not None else None,
            "resets_at": (reset := reset_time(window)) and reset.isoformat(),
            "window_seconds": window.get("windowSeconds"),
            "stale": bool((self.provider or {}).get("stale")),
        }


class ResetsSensor(WindowEntity, SensorEntity):
    """When the window resets."""

    _attr_translation_key = "resets"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str, window_id: str) -> None:
        super().__init__(coordinator, provider_id, window_id, "resets")

    @property
    def native_value(self) -> datetime | None:
        return reset_time(self.window or {})


class HistorySensor(WindowEntity):
    """Base for the sensors fed by GET /v1/history. They are available whenever
    the window is, and unknown while the companion has no prediction yet."""

    @property
    def history(self) -> dict[str, Any]:
        """The window's series, unless it belongs to an earlier cycle (the window
        reset while the history request was failing)."""
        series = self.coordinator.window_history(self.provider_id, self.window_id) or {}
        resets, expected = parse_time(series.get("resetsAt")), reset_time(self.window or {})
        if (resets is None) != (expected is None) or (
            resets is not None and expected is not None and abs((resets - expected).total_seconds()) > 120
        ):
            return {}
        return series

    @property
    def prediction(self) -> dict[str, Any]:
        value = self.history.get("prediction")
        return value if isinstance(value, dict) else {}


class ProjectedSensor(HistorySensor, SensorEntity):
    """Where the current rate of use ends at the reset, in percent (over 100
    means the limit is hit first). The attributes carry everything a chart of
    the cycle needs: the recorded points, the cycle's start and end."""

    _attr_translation_key = "projected"
    _attr_native_unit_of_measurement = PERCENTAGE
    _attr_state_class = SensorStateClass.MEASUREMENT
    _attr_suggested_display_precision = 0
    # About 6 KB at 300 points, rewritten every snapshot: keep it out of the database.
    _unrecorded_attributes = frozenset({"points"})

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str, window_id: str) -> None:
        super().__init__(coordinator, provider_id, window_id, "projected")

    @property
    def native_value(self) -> float | None:
        value = self.prediction.get("projectedAtReset")
        return round(float(value), 1) if isinstance(value, (int, float)) else None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        window = self.window or {}
        resets = reset_time(window)
        seconds = window.get("windowSeconds")
        start = resets - timedelta(seconds=seconds) if resets and isinstance(seconds, (int, float)) and seconds > 0 else None
        rate = self.prediction.get("ratePerHour")
        return {
            "window_start": start and start.isoformat(),
            "resets_at": resets and resets.isoformat(),
            "rate_per_hour": round(float(rate), 2) if isinstance(rate, (int, float)) else None,
            "basis": self.prediction.get("basis"),
            # [[epoch milliseconds, percent used], ...], oldest first
            "points": chart_points(self.history.get("points")),
        }


class RunsOutSensor(HistorySensor, SensorEntity):
    """When the window hits its limit at the current rate. Unknown when it
    won't before the reset."""

    _attr_translation_key = "runs_out"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, coordinator: MeterkatCoordinator, provider_id: str, window_id: str) -> None:
        super().__init__(coordinator, provider_id, window_id, "runsout")

    @property
    def native_value(self) -> datetime | None:
        return parse_time(self.prediction.get("runsOutAt"))


def chart_points(points: Any) -> list[list[float]]:
    """The companion's [epoch seconds, percent] pairs as [epoch milliseconds,
    percent], which is what chart cards plot."""
    if not isinstance(points, list):
        return []
    return [
        [int(point[0]) * 1000, round(float(point[1]), 1)]
        for point in points
        if isinstance(point, (list, tuple)) and len(point) == 2
        and all(isinstance(v, (int, float)) and math.isfinite(v) for v in point)
    ]
