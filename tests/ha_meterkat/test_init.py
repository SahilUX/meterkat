"""Setup, entities, the long-poll loop and diagnostics."""

from __future__ import annotations

import asyncio
import copy
import datetime as dt
from unittest.mock import AsyncMock, patch

import pytest
from homeassistant.config_entries import ConfigEntryState
from homeassistant.const import STATE_OFF, STATE_ON, STATE_UNAVAILABLE
from homeassistant.core import HomeAssistant
from homeassistant.helpers import device_registry as dr, entity_registry as er
from pytest_homeassistant_custom_component.components.diagnostics import get_diagnostics_for_config_entry

from custom_components.meterkat.api import MeterkatAuthError, MeterkatConnectionError
from custom_components.meterkat.const import DOMAIN

from homeassistant.helpers import issue_registry as ir
from pytest_homeassistant_custom_component.common import MockConfigEntry

from .conftest import HISTORY_FIXTURE, HISTORY_URL, HOST, PORT, SHARED_TOKEN, TOKEN, URL, USAGE_URL


class Stop(Exception):
    """Ends the watch loop in a test."""


async def _setup(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    aioclient_mock.get(USAGE_URL, json=snapshot)
    # A test that mocked the history URL first (a 404, say) keeps its answer: the first match wins.
    aioclient_mock.get(HISTORY_URL, json=HISTORY_FIXTURE)
    config_entry.add_to_hass(hass)
    # The long-poll task would block on the mock; tests drive async_watch directly.
    with patch("custom_components.meterkat.coordinator.MeterkatCoordinator.async_watch", AsyncMock()):
        assert await hass.config_entries.async_setup(config_entry.entry_id)
        await hass.async_block_till_done()


async def _watch(hass: HomeAssistant, config_entry, responses) -> None:
    """Run one pass of the long-poll loop per response, then stop it."""
    coordinator = config_entry.runtime_data
    calls = []

    async def get_usage(since=None, wait=0):
        calls.append((since, wait))
        if not responses:
            raise Stop
        item = responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    with (
        patch.object(coordinator.client, "async_get_usage", side_effect=get_usage),
        patch("custom_components.meterkat.coordinator.asyncio.sleep", AsyncMock()),
        pytest.raises(Stop),
    ):
        await coordinator.async_watch()
    await hass.async_block_till_done()
    return calls


async def test_entities(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    assert config_entry.state is ConfigEntryState.LOADED

    state = hass.states.get("sensor.claude_5_hour_used")
    assert state.state == "38.0"
    assert state.attributes["unit_of_measurement"] == "%"
    assert state.attributes["kind"] == "session"
    assert state.attributes["remaining"] == 62.0
    assert state.attributes["resets_at"] == "2026-10-25T01:40:00+00:00"
    assert "account" not in state.attributes

    assert hass.states.get("sensor.claude_5_hour_resets").state == "2026-10-25T01:40:00+00:00"
    assert hass.states.get("sensor.claude_weekly_resets").state == "2026-10-29T17:00:00+00:00"
    assert hass.states.get("sensor.claude_fable_used").state == "0.0"
    # Rounded to the minute: 18:32:02 -> 18:32, so a 1 s jitter changes nothing.
    assert hass.states.get("sensor.chatgpt_codex_weekly_resets").state == "2026-10-30T18:32:00+00:00"
    assert hass.states.get("sensor.chatgpt_codex_weekly_used").state == "59.0"
    assert hass.states.get("sensor.github_copilot_premium_requests_used").state == "55.5"
    assert hass.states.get("sensor.claude_status").state == "ok"
    assert hass.states.get("sensor.github_copilot_status").state == "error"
    assert hass.states.get("sensor.meterkat_companion_testbox_last_snapshot").state == "2026-10-24T21:50:51+00:00"

    assert hass.states.get("binary_sensor.claude_problem").state == STATE_OFF
    copilot = hass.states.get("binary_sensor.github_copilot_problem")
    assert copilot.state == STATE_ON
    assert copilot.attributes["reasons"] == ["error", "stale"]
    assert copilot.attributes["error"] == "GitHub returned HTTP 502"

    # Never signed in: no device, no entities.
    assert not [s for s in hass.states.async_entity_ids() if "kimi" in s]

    entity_registry = er.async_get(hass)
    assert entity_registry.async_get("sensor.claude_5_hour_used").unique_id == "testbox_claude_five_hour_used"
    assert entity_registry.async_get("binary_sensor.claude_problem").unique_id == "testbox_claude_problem"
    device = dr.async_get(hass).async_get_device_by_identifier((DOMAIN, "testbox_claude"), config_entry.entry_id)
    assert device.name == "Claude"
    assert device.model == "Max plan"
    hub = dr.async_get(hass).async_get_device_by_identifier((DOMAIN, "testbox"), config_entry.entry_id)
    assert device.via_device_id == hub.id
    assert hub.sw_version == "2.5.0"

    assert await hass.config_entries.async_unload(config_entry.entry_id)


async def test_stale_by_age(hass: HomeAssistant, config_entry, aioclient_mock, snapshot, frozen_time) -> None:
    frozen_time.move_to("2026-10-24T22:10:00+00:00")
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    state = hass.states.get("binary_sensor.claude_problem")
    assert state.state == STATE_ON
    assert state.attributes["reasons"] == ["stale"]


async def test_watch_updates_and_adds(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    newer = copy.deepcopy(snapshot)
    newer["generatedAt"] = "2026-10-24T21:52:51Z"
    claude = newer["providers"][0]
    claude["windows"][0]["percent"] = 41.0
    claude["windows"].append(
        {"id": "weekly_opus", "kind": "model", "label": "Opus", "percent": 7.0, "resetsAt": None, "windowSeconds": 604800}
    )
    newer["providers"][3].update(status="ok", error=None, fetchedAt="2026-10-24T21:52:46Z", plan="moderato",
                                 windows=[{"id": "weekly", "kind": "weekly", "label": "Weekly", "percent": 3.0,
                                           "resetsAt": None, "windowSeconds": 604800}])

    calls = await _watch(hass, config_entry, [newer])
    assert calls[0] == ("2026-10-24T21:50:51Z", 300)
    assert calls[1][0] == "2026-10-24T21:52:51Z"
    assert hass.states.get("sensor.claude_5_hour_used").state == "41.0"
    assert hass.states.get("sensor.claude_opus_used").state == "7.0"
    assert hass.states.get("sensor.claude_opus_resets").state == "unknown"
    assert hass.states.get("sensor.moonshot_kimi_weekly_used").state == "3.0"
    assert hass.states.get("binary_sensor.moonshot_kimi_problem").state == STATE_OFF

    # A window that goes away leaves its entity unavailable, not deleted.
    claude["windows"] = claude["windows"][:1]
    newer = copy.deepcopy(newer)
    newer["generatedAt"] = "2026-10-24T21:54:51Z"
    await _watch(hass, config_entry, [newer])
    assert hass.states.get("sensor.claude_opus_used").state == STATE_UNAVAILABLE
    assert await hass.config_entries.async_unload(config_entry.entry_id)


async def test_entities_survive_restart(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    """A provider with entities keeps them after a restart, even when it is
    no longer signed in."""
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    assert await hass.config_entries.async_unload(config_entry.entry_id)
    signed_out = copy.deepcopy(snapshot)
    signed_out["providers"][1].update(status="not_signed_in", windows=[], error="Codex is not signed in")
    aioclient_mock.clear_requests()
    aioclient_mock.get(USAGE_URL, json=signed_out)
    aioclient_mock.get(HISTORY_URL, json=HISTORY_FIXTURE)
    with patch("custom_components.meterkat.coordinator.MeterkatCoordinator.async_watch", AsyncMock()):
        assert await hass.config_entries.async_setup(config_entry.entry_id)
        await hass.async_block_till_done()
    problem = hass.states.get("binary_sensor.chatgpt_codex_problem")
    assert problem.state == STATE_ON
    assert problem.attributes["reasons"] == ["not_signed_in"]
    assert hass.states.get("sensor.chatgpt_codex_status").state == "not_signed_in"
    assert hass.states.get("sensor.chatgpt_codex_weekly_used").state == STATE_UNAVAILABLE


async def test_watch_connection_error(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    await _watch(hass, config_entry, [MeterkatConnectionError("refused")])
    assert hass.states.get("sensor.claude_5_hour_used").state == STATE_UNAVAILABLE
    problem = hass.states.get("binary_sensor.claude_problem")
    assert problem.state == STATE_ON
    assert problem.attributes["reasons"] == ["companion_unreachable"]

    await _watch(hass, config_entry, [snapshot])
    assert hass.states.get("sensor.claude_5_hour_used").state == "38.0"
    assert hass.states.get("binary_sensor.claude_problem").state == STATE_OFF


async def test_watch_auth_error_starts_reauth(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    coordinator = config_entry.runtime_data
    with patch.object(coordinator.client, "async_get_usage", AsyncMock(side_effect=MeterkatAuthError)), patch(
        "custom_components.meterkat.coordinator.asyncio.sleep", AsyncMock()
    ):
        await coordinator.async_watch()  # returns instead of retrying
    await hass.async_block_till_done()
    flows = hass.config_entries.flow.async_progress()
    assert [f["context"]["source"] for f in flows] == ["reauth"]


async def test_watch_old_companion_falls_back(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    """A companion that ignores `since` answers at once with the same snapshot;
    the loop must then wait instead of spinning."""
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    coordinator = config_entry.runtime_data
    sleeps = []

    async def fake_sleep(seconds):
        sleeps.append(seconds)

    responses = [snapshot, snapshot]

    async def get_usage(since=None, wait=0):
        if not responses:
            raise Stop
        return responses.pop(0)

    with patch.object(coordinator.client, "async_get_usage", side_effect=get_usage), patch(
        "custom_components.meterkat.coordinator.asyncio.sleep", side_effect=fake_sleep
    ), pytest.raises(Stop):
        await coordinator.async_watch()
    assert sleeps[1] >= 119


async def test_setup_auth_failure(hass: HomeAssistant, config_entry, aioclient_mock) -> None:
    aioclient_mock.get(USAGE_URL, status=401)
    config_entry.add_to_hass(hass)
    assert not await hass.config_entries.async_setup(config_entry.entry_id)
    assert config_entry.state is ConfigEntryState.SETUP_ERROR
    assert [f["context"]["source"] for f in hass.config_entries.flow.async_progress()] == ["reauth"]


async def test_setup_not_ready(hass: HomeAssistant, config_entry, aioclient_mock) -> None:
    aioclient_mock.get(USAGE_URL, exc=asyncio.TimeoutError())
    config_entry.add_to_hass(hass)
    assert not await hass.config_entries.async_setup(config_entry.entry_id)
    assert config_entry.state is ConfigEntryState.SETUP_RETRY


async def test_diagnostics(hass: HomeAssistant, hass_client, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    diagnostics = await get_diagnostics_for_config_entry(hass, hass_client, config_entry)
    text = str(diagnostics)
    assert TOKEN not in text
    assert "user@example.com" not in text and "example-user" not in text
    assert diagnostics["entry"]["data"]["token"] == "**REDACTED**"
    assert diagnostics["snapshot"]["providers"][0]["account"] == "**REDACTED**"
    assert diagnostics["snapshot"]["providers"][0]["windows"][0]["percent"] == 38.0


async def test_a_version_1_entry_is_migrated_to_a_url(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id="testbox", version=1,
                            data={"host": HOST, "port": PORT, "token": SHARED_TOKEN})
    await _setup(hass, entry, aioclient_mock, snapshot)
    assert entry.version == 2
    assert entry.data == {"url": URL, "token": SHARED_TOKEN, "verify_ssl": True}
    assert hass.states.get("sensor.claude_5_hour_used").state == "38.0"
    assert entry.unique_id == "testbox"  # entity unique IDs are built on it


async def test_a_future_entry_version_is_refused(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    entry = MockConfigEntry(domain=DOMAIN, version=3, data={"url": URL, "token": TOKEN})
    entry.add_to_hass(hass)
    assert not await hass.config_entries.async_setup(entry.entry_id)
    assert entry.state is ConfigEntryState.MIGRATION_ERROR


async def test_the_shared_token_is_flagged_and_a_device_token_is_not(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    shared = MockConfigEntry(domain=DOMAIN, unique_id="testbox", version=2,
                             data={"url": URL, "token": SHARED_TOKEN, "verify_ssl": True})
    await _setup(hass, shared, aioclient_mock, snapshot)
    issues = ir.async_get(hass)
    assert issues.async_get_issue(DOMAIN, "shared_token_%s" % shared.entry_id)
    # Pairing again swaps in a device token; the notice goes away on the next setup.
    hass.config_entries.async_update_entry(shared, data={**shared.data, "token": TOKEN})
    await hass.config_entries.async_reload(shared.entry_id)
    await hass.async_block_till_done()
    assert not issues.async_get_issue(DOMAIN, "shared_token_%s" % shared.entry_id)


async def test_an_old_companion_is_not_nagged(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    snapshot["companionVersion"] = "2.4.2"
    entry = MockConfigEntry(domain=DOMAIN, unique_id="testbox", version=2,
                            data={"url": URL, "token": SHARED_TOKEN, "verify_ssl": True})
    await _setup(hass, entry, aioclient_mock, snapshot)
    assert not ir.async_get(hass).async_get_issue(DOMAIN, "shared_token_%s" % entry.entry_id)


async def test_the_issue_goes_when_the_entry_is_removed(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id="testbox", version=2,
                            data={"url": URL, "token": SHARED_TOKEN, "verify_ssl": True})
    await _setup(hass, entry, aioclient_mock, snapshot)
    await hass.config_entries.async_remove(entry.entry_id)
    assert not ir.async_get(hass).async_get_issue(DOMAIN, "shared_token_%s" % entry.entry_id)


async def test_a_missing_ca_file_retries_setup(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id="testbox", version=2,
                            data={"url": URL, "token": TOKEN, "verify_ssl": True, "ca_file": "/nope.pem"})
    entry.add_to_hass(hass)
    assert not await hass.config_entries.async_setup(entry.entry_id)
    assert entry.state is ConfigEntryState.SETUP_RETRY


def _ms(value: str) -> int:
    return int(dt.datetime.fromisoformat(value).timestamp()) * 1000


async def test_chart_sensors(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    projected = hass.states.get("sensor.claude_5_hour_projected_at_reset")
    assert projected.state == "127.2"
    assert projected.attributes["unit_of_measurement"] == "%"
    assert projected.attributes["window_start"] == "2026-10-24T20:40:00+00:00"
    assert projected.attributes["resets_at"] == "2026-10-25T01:40:00+00:00"
    assert projected.attributes["rate_per_hour"] == 24.0
    assert projected.attributes["basis"] == "recent_trend"
    points = projected.attributes["points"]
    assert len(points) == 4
    assert points[0] == [_ms("2026-10-24T20:40:00+00:00"), 0.0]
    assert points[-1] == [_ms("2026-10-24T21:52:00+00:00"), 38.0]
    assert hass.states.get("sensor.claude_5_hour_runs_out").state == "2026-10-24T23:30:00+00:00"
    # Fine until the reset: no run-out time. No prediction yet: unknown, with an empty chart.
    assert hass.states.get("sensor.claude_weekly_runs_out").state == "unknown"
    assert hass.states.get("sensor.claude_weekly_projected_at_reset").state == "98.0"
    empty = hass.states.get("sensor.claude_fable_projected_at_reset")
    assert empty.state == "unknown"
    assert empty.attributes["points"] == []


async def test_chart_points_stay_out_of_the_recorder(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    from custom_components.meterkat.sensor import ProjectedSensor

    assert "points" in ProjectedSensor._unrecorded_attributes


async def test_history_follows_each_new_snapshot(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    coordinator = config_entry.runtime_data
    newer = copy.deepcopy(snapshot)
    newer["generatedAt"] = "2026-10-24T21:52:51Z"
    later = copy.deepcopy(HISTORY_FIXTURE)
    later["series"][0]["prediction"]["projectedAtReset"] = 140.0
    with patch.object(coordinator.client, "async_get_history", AsyncMock(return_value=later["series"])):
        await _watch(hass, config_entry, [newer])
    assert hass.states.get("sensor.claude_5_hour_projected_at_reset").state == "140.0"


async def test_a_failing_history_request_changes_nothing(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    coordinator = config_entry.runtime_data
    newer = copy.deepcopy(snapshot)
    newer["generatedAt"] = "2026-10-24T21:52:51Z"
    newer["providers"][0]["windows"][0]["percent"] = 41.0
    with patch.object(coordinator.client, "async_get_history", AsyncMock(side_effect=MeterkatConnectionError("boom"))):
        await _watch(hass, config_entry, [newer])
    assert hass.states.get("sensor.claude_5_hour_used").state == "41.0"
    assert hass.states.get("sensor.claude_5_hour_projected_at_reset").state == "127.2"


async def test_a_companion_without_history_still_works(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    aioclient_mock.get(HISTORY_URL, status=404)
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    assert hass.states.get("sensor.claude_5_hour_used").state == "38.0"
    assert hass.states.get("sensor.claude_5_hour_projected_at_reset").state == "unknown"
    assert hass.states.get("sensor.claude_5_hour_runs_out").state == "unknown"
    assert config_entry.runtime_data._no_history_for == ("2.5.0",)


async def test_a_series_from_an_earlier_cycle_is_ignored(hass: HomeAssistant, config_entry, aioclient_mock, snapshot) -> None:
    """The window resets while history requests fail: the old points must not be drawn over the new cycle."""
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    coordinator = config_entry.runtime_data
    newer = copy.deepcopy(snapshot)
    newer["generatedAt"] = "2026-10-24T21:52:51Z"
    newer["providers"][0]["windows"][0]["resetsAt"] = "2026-10-25T06:40:00Z"
    newer["providers"][0]["windows"][0]["percent"] = 2.0
    with patch.object(coordinator.client, "async_get_history", AsyncMock(side_effect=MeterkatConnectionError("down"))):
        await _watch(hass, config_entry, [newer])
    state = hass.states.get("sensor.claude_5_hour_projected_at_reset")
    assert state.state == "unknown"
    assert state.attributes["points"] == []
    assert hass.states.get("sensor.claude_5_hour_runs_out").state == "unknown"
    # A second's jitter in the reset time is the same cycle.
    jitter = copy.deepcopy(snapshot)
    jitter["generatedAt"] = "2026-10-24T21:53:51Z"
    jitter["providers"][0]["windows"][0]["resetsAt"] = "2026-10-25T01:40:01Z"
    with patch.object(coordinator.client, "async_get_history", AsyncMock(side_effect=MeterkatConnectionError("down"))):
        await _watch(hass, config_entry, [jitter])
    assert hass.states.get("sensor.claude_5_hour_projected_at_reset").state == "127.2"


async def test_history_is_asked_again_when_the_companion_version_changes(
    hass: HomeAssistant, config_entry, aioclient_mock, snapshot
) -> None:
    aioclient_mock.get(HISTORY_URL, status=404)
    await _setup(hass, config_entry, aioclient_mock, snapshot)
    coordinator = config_entry.runtime_data
    calls = AsyncMock(return_value=HISTORY_FIXTURE["series"])
    same = copy.deepcopy(snapshot)
    same["generatedAt"] = "2026-10-24T21:52:51Z"
    with patch.object(coordinator.client, "async_get_history", calls):
        await _watch(hass, config_entry, [same])
        calls.assert_not_awaited()  # still the version that answered 404
        upgraded = copy.deepcopy(snapshot)
        upgraded["generatedAt"] = "2026-10-24T21:54:51Z"
        upgraded["companionVersion"] = "2.5.4"
        await _watch(hass, config_entry, [upgraded])
        calls.assert_awaited_once()
    assert hass.states.get("sensor.claude_5_hour_projected_at_reset").state == "127.2"


@pytest.mark.parametrize(
    ("kwargs", "result"),
    [
        ({"json": HISTORY_FIXTURE}, "series"),
        ({"status": 404}, None),
        ({"status": 401}, MeterkatAuthError),
        ({"status": 500}, MeterkatConnectionError),
        ({"json": {"series": "nope"}}, MeterkatConnectionError),
    ],
)
async def test_client_history(hass: HomeAssistant, aioclient_mock, kwargs, result) -> None:
    from homeassistant.helpers.aiohttp_client import async_get_clientsession

    from custom_components.meterkat.api import MeterkatClient

    aioclient_mock.get(HISTORY_URL, **kwargs)
    client = MeterkatClient(async_get_clientsession(hass), URL, TOKEN)
    if isinstance(result, type):
        with pytest.raises(result):
            await client.async_get_history()
    elif result == "series":
        assert await client.async_get_history() == HISTORY_FIXTURE["series"]
    else:
        assert await client.async_get_history() is result
    assert aioclient_mock.mock_calls[0][3]["Authorization"] == "Bearer " + TOKEN
