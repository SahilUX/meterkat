"""Keeps the latest Meterkat snapshot, following the companion's long-poll."""

from __future__ import annotations

import asyncio
import time
from datetime import datetime
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

from .api import MeterkatAuthError, MeterkatClient, MeterkatConnectionError
from .const import (
    CONF_SCAN_INTERVAL,
    DEFAULT_SCAN_INTERVAL,
    DOMAIN,
    FALLBACK_POLL_SECONDS,
    LOGGER,
    LONG_POLL_WAIT,
    RETRY_SECONDS,
    STALE_AFTER_SECONDS,
    STATUS_OK,
)

type MeterkatConfigEntry = ConfigEntry[MeterkatCoordinator]


def parse_time(value: Any) -> datetime | None:
    return dt_util.parse_datetime(value) if isinstance(value, str) else None


def provider_problems(provider: dict[str, Any], now: datetime | None = None) -> list[str]:
    """Why a provider's reading can't be trusted: its status, a stale flag, or age."""
    problems = []
    status = provider.get("status")
    if status != STATUS_OK:
        problems.append(str(status))
    if provider.get("stale"):
        problems.append("stale")
    else:
        fetched = parse_time(provider.get("fetchedAt"))
        now = now or dt_util.utcnow()
        if status == STATUS_OK and (
            fetched is None or (now - fetched).total_seconds() > STALE_AFTER_SECONDS
        ):
            problems.append("stale")
    return problems


class MeterkatCoordinator(DataUpdateCoordinator[dict[str, Any]]):
    """Holds the snapshot from GET /v1/usage.

    There is no update interval. After the first refresh, async_watch() long-polls
    `?since=<generatedAt>`, so each snapshot arrives as soon as the companion's
    own background poll builds it. The history read that follows can make the
    companion refresh its cache once when that cache is over a minute old (right
    after a restart); in steady state the snapshot is fresh and it never does.
    """

    config_entry: MeterkatConfigEntry

    def __init__(self, hass: HomeAssistant, entry: MeterkatConfigEntry, client: MeterkatClient) -> None:
        super().__init__(hass, LOGGER, config_entry=entry, name=DOMAIN, update_interval=None)
        self.client = client
        self.hub_device_id: str | None = None
        # (provider id, window id) -> the series from GET /v1/history; empty
        # when the companion has none or the last request failed.
        self.history: dict[tuple[str, str], dict[str, Any]] = {}
        # The companion version that answered /v1/history with a 404; ask again when it changes.
        self._no_history_for: tuple[Any] | None = None

    @property
    def min_interval(self) -> int:
        return int(self.config_entry.options.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL))

    def provider(self, provider_id: str) -> dict[str, Any] | None:
        for provider in (self.data or {}).get("providers", []):
            if provider.get("id") == provider_id:
                return provider
        return None

    def window(self, provider_id: str, window_id: str) -> dict[str, Any] | None:
        provider = self.provider(provider_id)
        for window in (provider or {}).get("windows") or []:
            if window.get("id") == window_id:
                return window
        return None

    def window_history(self, provider_id: str, window_id: str) -> dict[str, Any] | None:
        return self.history.get((provider_id, window_id))

    async def _async_update_data(self) -> dict[str, Any]:
        try:
            data = await self.client.async_get_usage(self._since())
        except MeterkatAuthError as err:
            raise ConfigEntryAuthFailed("The companion rejected the token") from err
        except MeterkatConnectionError as err:
            raise UpdateFailed("Cannot reach the companion: %s" % err) from err
        await self._async_refresh_history(data)
        return data

    async def _async_refresh_history(self, snapshot: dict[str, Any]) -> bool:
        """Read the chart history that goes with a snapshot. Best effort: it
        never fails an update, and a failed request keeps the previous series
        (the chart sensors ignore a series from an earlier cycle). True when
        the stored series changed."""
        version = (snapshot.get("companionVersion"),)
        if self._no_history_for == version:
            return False
        try:
            series = await self.client.async_get_history()
        except (MeterkatAuthError, MeterkatConnectionError) as err:
            LOGGER.debug("Meterkat history unavailable: %s", err)
            return False
        if series is None:
            self._no_history_for = version
            changed = bool(self.history)
            self.history = {}
            return changed
        self._no_history_for = None
        history = {
            (s["provider"], s["window"]): s
            for s in series
            if isinstance(s.get("provider"), str) and isinstance(s.get("window"), str)
        }
        changed = history != self.history
        self.history = history
        return changed

    def _since(self) -> str | None:
        return (self.data or {}).get("generatedAt")

    async def async_watch(self) -> None:
        """Runs for the life of the config entry as a background task."""
        last_update = time.monotonic()
        while True:
            await asyncio.sleep(max(0.0, last_update + self.min_interval - time.monotonic()))
            since = self._since()
            started = time.monotonic()
            try:
                data = await self.client.async_get_usage(since, LONG_POLL_WAIT)
            except MeterkatAuthError:
                self.async_set_update_error(ConfigEntryAuthFailed("The companion rejected the token"))
                self.config_entry.async_start_reauth(self.hass)
                return
            except MeterkatConnectionError as err:
                self.async_set_update_error(UpdateFailed(str(err)))
                last_update = time.monotonic() - self.min_interval + RETRY_SECONDS
                continue
            if not self.last_update_success:
                LOGGER.info("Meterkat companion is back")
            self.async_set_updated_data(data)
            # After the usage sensors: a slow history request must not delay them.
            if await self._async_refresh_history(data):
                self.async_update_listeners()
            last_update = time.monotonic()
            if since is not None and data.get("generatedAt") == since and last_update - started < 1:
                # A companion older than 2.3.0 ignores `since`: fall back to polling.
                last_update += max(0, FALLBACK_POLL_SECONDS - self.min_interval)
