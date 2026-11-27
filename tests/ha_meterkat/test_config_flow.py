"""Config, reauth, reconfigure and options flows."""

from __future__ import annotations

import dataclasses
import ssl as ssl_lib
from ipaddress import ip_address
from unittest.mock import Mock, patch

import aiohttp
import pytest
from homeassistant import config_entries
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.helpers.service_info.zeroconf import ZeroconfServiceInfo
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.meterkat.api import (
    MeterkatInvalidLink,
    MeterkatInvalidUrl,
    normalize_url,
    parse_pairing_link,
)
from custom_components.meterkat.const import CONF_SCAN_INTERVAL, DOMAIN

from .conftest import HEALTH, HOST, PORT, SHARED_TOKEN, TOKEN, URL, USAGE_URL

CODE = "abc123"
LINK = (
    "meterkat://pair?local=http%3A%2F%2F192.168.1.20%3A47300"
    "&remote=http%3A%2F%2Fdevbox.example.ts.net%3A47300&name=testbox&code=" + CODE
)
REMOTE = "http://devbox.example.ts.net:47300"
PROXY = "https://meterkat.example.com"


@pytest.fixture(autouse=True)
def no_setup():
    with patch("custom_components.meterkat.async_setup_entry", return_value=True):
        yield


def _companion(aioclient_mock, snapshot, url=URL, token=TOKEN, health=None):
    """A companion that accepts one pairing and then the token it hands out."""
    aioclient_mock.get(url + "/health", json=health or HEALTH)
    aioclient_mock.post(url + "/v1/pair", json={"token": token, "deviceId": "ab12cd34", "role": "viewer"})
    aioclient_mock.get(url + "/v1/usage", json=snapshot)


async def _menu(hass: HomeAssistant, step: str):
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    assert result["type"] is FlowResultType.MENU
    assert set(result["menu_options"]) == {"pairing_link", "url", "legacy_token"}
    return await hass.config_entries.flow.async_configure(result["flow_id"], {"next_step_id": step})


def _paired_with_name(aioclient_mock, url=URL):
    posts = [c for c in aioclient_mock.mock_calls if c[0].lower() == "post" and str(c[1]).startswith(url)]
    return posts[-1][2]


# -- pairing link --

async def test_pairing_link(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    _companion(aioclient_mock, snapshot)
    result = await _menu(hass, "pairing_link")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_link": LINK})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["title"] == "Meterkat (testbox)"
    assert result["data"] == {"url": URL, "token": TOKEN, "verify_ssl": True}
    assert result["result"].unique_id == "abc123abc123"  # the companion's own id, not its hostname
    assert _paired_with_name(aioclient_mock) == {"code": CODE, "name": "Home Assistant"}
    usage = [c for c in aioclient_mock.mock_calls if c[1].path == "/v1/usage"][-1]
    assert usage[3]["Authorization"] == "Bearer " + TOKEN
    # Always `since`, so validating never makes the companion fetch providers.
    assert usage[1].query["since"] == "0" and usage[1].query["wait"] == "0"


async def test_pairing_link_falls_back_to_the_remote_address(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    aioclient_mock.get(URL + "/health", exc=aiohttp.ClientError())
    _companion(aioclient_mock, snapshot, url=REMOTE)
    result = await _menu(hass, "pairing_link")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_link": LINK})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"]["url"] == REMOTE


@pytest.mark.parametrize(
    ("link", "mocks", "error"),
    [
        ("https://example.com/pair?code=x", {}, "invalid_link"),
        ("meterkat://pair?local=http%3A%2F%2F192.168.1.20%3A47300", {}, "invalid_link"),
        (LINK, {"pair": {"status": 401}}, "pairing_failed"),
        (LINK, {"health": {"exc": aiohttp.ClientError()}}, "cannot_connect"),
        (LINK, {"health": {"json": {"ok": True, "version": "2.4.2", "pollSeconds": 120}}}, "companion_too_old"),
        (LINK, {"health": {"json": {"hello": "world"}}}, "not_meterkat"),
        (LINK, {"health": {"status": 404}}, "not_meterkat"),
        (LINK, {"pair": {"status": 429}}, "cannot_connect"),
        (LINK, {"usage": {"status": 401}}, "invalid_auth"),
    ],
)
async def test_pairing_link_errors(hass: HomeAssistant, aioclient_mock, snapshot, link, mocks, error) -> None:
    for base in (URL, REMOTE):
        aioclient_mock.get(base + "/health", **mocks.get("health", {"json": HEALTH}))
        aioclient_mock.post(base + "/v1/pair", **mocks.get("pair", {"json": {"token": TOKEN}}))
        aioclient_mock.get(base + "/v1/usage", **mocks.get("usage", {"json": snapshot}))
    result = await _menu(hass, "pairing_link")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_link": link})
    assert result["type"] is FlowResultType.FORM
    assert result["errors"] == {"base": error}


def test_parse_pairing_link() -> None:
    link = parse_pairing_link(LINK)
    assert link.code == CODE
    assert link.urls == [URL, REMOTE]
    assert link.name == "testbox"
    with pytest.raises(MeterkatInvalidLink):
        parse_pairing_link("meterkat://pair?code=abc")


# -- URL and code --

@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("192.168.1.20", "http://192.168.1.20:47300"),
        ("  box.local  ", "http://box.local:47300"),
        ("http://box.local:5000/", "http://box.local:5000"),
        ("https://meterkat.example.com", "https://meterkat.example.com"),
        ("https://box.ts.net:47300/meterkat/", "https://box.ts.net:47300/meterkat"),
        ("http://[fd00::1]", "http://[fd00::1]:47300"),
    ],
)
def test_normalize_url(text, expected) -> None:
    assert normalize_url(text) == expected


@pytest.mark.parametrize("text", ["", "   ", "ftp://box", "http://", "box:99999", "http://box?x=1", "meterkat://pair"])
def test_normalize_url_rejects(text) -> None:
    with pytest.raises(MeterkatInvalidUrl):
        normalize_url(text)


async def test_url_with_a_code_over_https(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    _companion(aioclient_mock, snapshot, url=PROXY)
    result = await _menu(hass, "url")
    assert result["step_id"] == "url"
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": PROXY + "/", "pairing_code": " " + CODE + " ", "verify_ssl": True}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"] == {"url": PROXY, "token": TOKEN, "verify_ssl": True}
    assert _paired_with_name(aioclient_mock, PROXY) == {"code": CODE, "name": "Home Assistant"}


async def test_url_accepts_the_whole_link_in_the_code_field(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    _companion(aioclient_mock, snapshot, url=PROXY)
    result = await _menu(hass, "url")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": PROXY, "pairing_code": LINK, "verify_ssl": True}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"]["url"] == PROXY  # the entered address first, not the link's


async def test_url_can_skip_certificate_verification(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    _companion(aioclient_mock, snapshot, url=PROXY)
    result = await _menu(hass, "url")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": PROXY, "pairing_code": CODE, "verify_ssl": False}
    )
    assert result["data"]["verify_ssl"] is False
    from custom_components.meterkat import async_ssl_option

    assert await async_ssl_option(hass, result["data"]) is False


async def test_url_with_a_custom_ca(hass: HomeAssistant, aioclient_mock, snapshot, tmp_path) -> None:
    _companion(aioclient_mock, snapshot, url=PROXY)
    context = Mock(spec=ssl_lib.SSLContext)
    result = await _menu(hass, "url")
    with patch("custom_components.meterkat.ssl_lib.create_default_context", return_value=context) as create:
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"],
            {"url": PROXY, "pairing_code": CODE, "verify_ssl": True, "ca_file": "/config/certs/ca.pem"},
        )
    create.assert_called_with(cafile="/config/certs/ca.pem")
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"]["ca_file"] == "/config/certs/ca.pem"


async def test_url_unreadable_ca_file(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    result = await _menu(hass, "url")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": PROXY, "pairing_code": CODE, "verify_ssl": True, "ca_file": "/nope/ca.pem"}
    )
    assert result["errors"] == {"ca_file": "ca_file_unreadable"}


@pytest.mark.parametrize(
    ("url", "mocks", "errors"),
    [
        ("ftp://box", {}, {"url": "invalid_url"}),
        (PROXY, {"health": {"exc": aiohttp.ClientError()}}, {"base": "cannot_connect"}),
        (PROXY, {"health": {"exc": aiohttp.ClientConnectorSSLError(Mock(), OSError())}}, {"base": "ssl_error"}),
        (PROXY, {"health": {"json": {"version": "9"}}}, {"base": "not_meterkat"}),
        (PROXY, {"health": {"json": {"ok": True, "version": "2.4.1", "pollSeconds": 120}}}, {"base": "companion_too_old"}),
        (PROXY, {"pair": {"status": 401}}, {"base": "pairing_failed"}),
        (PROXY, {"pair": {"status": 400}}, {"base": "pairing_failed"}),
    ],
)
async def test_url_errors(hass: HomeAssistant, aioclient_mock, snapshot, url, mocks, errors) -> None:
    aioclient_mock.get(PROXY + "/health", **mocks.get("health", {"json": HEALTH}))
    aioclient_mock.post(PROXY + "/v1/pair", **mocks.get("pair", {"json": {"token": TOKEN}}))
    aioclient_mock.get(PROXY + "/v1/usage", json=snapshot)
    result = await _menu(hass, "url")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": url, "pairing_code": CODE, "verify_ssl": True}
    )
    assert result["type"] is FlowResultType.FORM
    assert result["errors"] == errors
    # and the form still works once the problem is fixed
    aioclient_mock.clear_requests()
    _companion(aioclient_mock, snapshot, url=PROXY)
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": PROXY, "pairing_code": CODE, "verify_ssl": True}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY


# -- older companions --

async def test_legacy_token(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    snapshot.pop("companionId")
    snapshot["companionVersion"] = "2.4.2"
    aioclient_mock.get(URL + "/health", json={"ok": True, "version": "2.4.2", "pollSeconds": 120})
    aioclient_mock.get(USAGE_URL, json=snapshot)
    result = await _menu(hass, "legacy_token")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"host": f" {HOST} ", "port": PORT, "token": f" {SHARED_TOKEN} "}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"] == {"url": URL, "token": SHARED_TOKEN, "verify_ssl": True}
    assert result["result"].unique_id == "testbox"  # no companion id: the hostname


@pytest.mark.parametrize(
    ("health", "usage", "error"),
    [
        ({"exc": aiohttp.ClientError()}, {"json": {}}, "cannot_connect"),
        ({"json": {"x": 1}}, {"json": {}}, "not_meterkat"),
        ({"json": HEALTH}, {"status": 401}, "invalid_auth"),
        ({"json": HEALTH}, {"status": 500}, "cannot_connect"),
        ({"json": HEALTH}, {"json": {"nope": 1}}, "cannot_connect"),
    ],
)
async def test_legacy_token_errors(hass: HomeAssistant, aioclient_mock, health, usage, error) -> None:
    aioclient_mock.get(URL + "/health", **health)
    aioclient_mock.get(USAGE_URL, **usage)
    result = await _menu(hass, "legacy_token")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"host": HOST, "port": PORT, "token": SHARED_TOKEN}
    )
    assert result["errors"] == {"base": error}


# -- one entry per companion --

async def test_a_companion_added_twice_updates_the_first_entry(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    entry = MockConfigEntry(
        domain=DOMAIN, unique_id="abc123abc123", version=2,
        data={"url": "http://10.0.0.9:47300", "token": "old", "verify_ssl": True},
    )
    entry.add_to_hass(hass)
    _companion(aioclient_mock, snapshot)
    result = await _menu(hass, "pairing_link")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_link": LINK})
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "already_configured"
    assert entry.data["url"] == URL and entry.data["token"] == TOKEN


async def test_an_entry_keyed_by_hostname_is_recognized(hass: HomeAssistant, aioclient_mock, snapshot, config_entry) -> None:
    """Entries from before companion ids (unique ID = the hostname) are the same companion."""
    config_entry.add_to_hass(hass)
    _companion(aioclient_mock, snapshot, token="mkd_ee00ff11_new")
    result = await _menu(hass, "pairing_link")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_link": LINK})
    assert result["reason"] == "already_configured"
    assert config_entry.data["token"] == "mkd_ee00ff11_new"
    assert len(hass.config_entries.async_entries(DOMAIN)) == 1


# -- discovery --

def _discovery(version="2.5.0", cid="abc123abc123", host="testbox"):
    return ZeroconfServiceInfo(
        ip_address=ip_address(HOST),
        ip_addresses=[ip_address(HOST)],
        port=PORT,
        hostname=host + ".local.",
        type="_meterkat._tcp.local.",
        name=host + "._meterkat._tcp.local.",
        properties={"version": version, "id": cid, "host": host, "path": "/v1/usage"},
    )


async def test_zeroconf(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    _companion(aioclient_mock, snapshot)
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=_discovery()
    )
    assert result["type"] is FlowResultType.FORM
    assert result["step_id"] == "zeroconf_confirm"
    assert result["description_placeholders"] == {"name": "testbox", "url": URL}
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_code": CODE})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"] == {"url": URL, "token": TOKEN, "verify_ssl": True}
    assert result["result"].unique_id == "abc123abc123"


async def test_zeroconf_wrong_code_can_be_retried(hass: HomeAssistant, aioclient_mock, snapshot) -> None:
    aioclient_mock.get(URL + "/health", json=HEALTH)
    aioclient_mock.post(URL + "/v1/pair", status=401)
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=_discovery()
    )
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_code": "bad"})
    assert result["errors"] == {"base": "pairing_failed"}


async def test_zeroconf_ignores_a_companion_that_is_set_up_and_follows_its_address(
    hass: HomeAssistant, config_entry
) -> None:
    config_entry.add_to_hass(hass)
    info = _discovery()
    info = dataclasses.replace(info, ip_address=ip_address("192.168.1.42"), ip_addresses=[ip_address("192.168.1.42")])
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=info
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "already_configured"
    assert config_entry.data["url"] == "http://192.168.1.42:47300"


async def test_zeroconf_never_replaces_an_https_address(hass: HomeAssistant) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id="abc123abc123", version=2,
                            data={"url": PROXY, "token": TOKEN, "verify_ssl": True})
    entry.add_to_hass(hass)
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=_discovery()
    )
    assert result["reason"] == "already_configured"
    assert entry.data["url"] == PROXY


async def test_zeroconf_old_companion(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=_discovery(version="2.4.2")
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "companion_too_old"


# -- reauth and reconfigure --

async def test_reauth_with_a_pairing_code(hass: HomeAssistant, aioclient_mock, snapshot, config_entry) -> None:
    config_entry.add_to_hass(hass)
    result = await config_entry.start_reauth_flow(hass)
    assert result["step_id"] == "reauth_confirm"
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["errors"] == {"base": "missing_credentials"}

    aioclient_mock.get(URL + "/health", json=HEALTH)
    aioclient_mock.post(URL + "/v1/pair", status=401)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_code": "stale"})
    assert result["errors"] == {"base": "pairing_failed"}

    aioclient_mock.clear_requests()
    _companion(aioclient_mock, snapshot, token="mkd_ee00ff11_new")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"pairing_code": LINK})
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "reauth_successful"
    assert config_entry.data["token"] == "mkd_ee00ff11_new"
    assert config_entry.data["url"] == URL


async def test_reauth_with_a_legacy_token(hass: HomeAssistant, aioclient_mock, snapshot, config_entry) -> None:
    config_entry.add_to_hass(hass)
    result = await config_entry.start_reauth_flow(hass)
    aioclient_mock.get(USAGE_URL, status=401)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"token": "still-wrong"})
    assert result["errors"] == {"base": "invalid_auth"}
    aioclient_mock.clear_requests()
    aioclient_mock.get(USAGE_URL, json=snapshot)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"token": "rotated"})
    assert result["reason"] == "reauth_successful"
    assert config_entry.data["token"] == "rotated"


async def test_reauth_wrong_companion(hass: HomeAssistant, aioclient_mock, snapshot, config_entry) -> None:
    config_entry.add_to_hass(hass)
    snapshot.update(host="otherbox", companionId="ffffffffffff")
    aioclient_mock.get(USAGE_URL, json=snapshot)
    result = await config_entry.start_reauth_flow(hass)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"token": "other"})
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "wrong_companion"
    assert config_entry.data["token"] == TOKEN


async def test_reconfigure_moves_a_shared_token_entry_to_its_own_token(
    hass: HomeAssistant, aioclient_mock, snapshot
) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id="testbox", version=2,
                            data={"url": URL, "token": SHARED_TOKEN, "verify_ssl": True})
    entry.add_to_hass(hass)
    result = await entry.start_reconfigure_flow(hass)
    assert result["step_id"] == "reconfigure"
    _companion(aioclient_mock, snapshot)
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": URL, "pairing_code": LINK, "verify_ssl": True}
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "reconfigure_successful"
    assert entry.data["token"] == TOKEN
    assert entry.unique_id == "testbox"  # entity IDs are built on it, so it stays


async def test_reconfigure_changes_the_address_and_keeps_the_token(hass: HomeAssistant, aioclient_mock, snapshot, config_entry) -> None:
    config_entry.add_to_hass(hass)
    aioclient_mock.get(PROXY + "/v1/usage", json=snapshot)
    result = await config_entry.start_reconfigure_flow(hass)
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"url": PROXY, "verify_ssl": False}
    )
    assert result["reason"] == "reconfigure_successful"
    assert config_entry.data == {"url": PROXY, "token": TOKEN, "verify_ssl": False}


async def test_reconfigure_errors(hass: HomeAssistant, aioclient_mock, snapshot, config_entry) -> None:
    config_entry.add_to_hass(hass)
    result = await config_entry.start_reconfigure_flow(hass)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"url": "ftp://x", "verify_ssl": True})
    assert result["errors"] == {"url": "invalid_url"}
    aioclient_mock.get(PROXY + "/v1/usage", status=401)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"url": PROXY, "verify_ssl": True})
    assert result["errors"] == {"base": "invalid_auth"}
    snapshot.update(host="otherbox", companionId="ffffffffffff")
    aioclient_mock.clear_requests()
    aioclient_mock.get(PROXY + "/v1/usage", json=snapshot)
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"url": PROXY, "verify_ssl": True})
    assert result["reason"] == "wrong_companion"


async def test_options(hass: HomeAssistant, config_entry) -> None:
    config_entry.add_to_hass(hass)
    result = await hass.config_entries.options.async_init(config_entry.entry_id)
    assert result["type"] is FlowResultType.FORM
    result = await hass.config_entries.options.async_configure(result["flow_id"], {CONF_SCAN_INTERVAL: 120})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert config_entry.options == {CONF_SCAN_INTERVAL: 120}
