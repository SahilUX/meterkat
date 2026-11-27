"""Config flow for Meterkat.

A companion is added by pairing: paste the pairing link, or give the companion's URL and
a pairing code. Pairing creates this integration's own token on the companion, so it can
be revoked without touching any other device. A companion older than 2.5.0 has no per-device
tokens; for those, enter host, port and the companion's shared token.
"""

from __future__ import annotations

import ssl as ssl_lib
from collections.abc import Mapping
from typing import Any

import voluptuous as vol

from homeassistant.config_entries import ConfigEntry, ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.const import CONF_HOST, CONF_PORT, CONF_TOKEN
from homeassistant.core import callback
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.selector import (
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)
from homeassistant.helpers.service_info.zeroconf import ZeroconfServiceInfo

from . import async_ssl_option
from .api import (
    MeterkatAuthError,
    MeterkatClient,
    MeterkatConnectionError,
    MeterkatInvalidLink,
    MeterkatInvalidUrl,
    MeterkatNotACompanion,
    MeterkatPairingError,
    MeterkatSslError,
    SslOption,
    async_health,
    async_redeem_code,
    display_host,
    normalize_url,
    parse_pairing_link,
    supports_device_tokens,
    url_from_host_port,
)
from .const import (
    CONF_CA_FILE,
    CONF_PAIRING_CODE,
    CONF_PAIRING_LINK,
    CONF_SCAN_INTERVAL,
    CONF_URL,
    CONF_VERIFY_SSL,
    DEFAULT_PORT,
    DEFAULT_SCAN_INTERVAL,
    DOMAIN,
    LOGGER,
    MAX_SCAN_INTERVAL,
    MIN_SCAN_INTERVAL,
)

PASSWORD = TextSelector(TextSelectorConfig(type=TextSelectorType.PASSWORD))
LINK_SCHEMA = vol.Schema({vol.Required(CONF_PAIRING_LINK): PASSWORD})
CODE_SCHEMA = vol.Schema({vol.Required(CONF_PAIRING_CODE): PASSWORD})


def _url_schema(defaults: Mapping[str, Any], code_required: bool = True) -> vol.Schema:
    code = vol.Required if code_required else vol.Optional
    return vol.Schema(
        {
            vol.Required(CONF_URL, default=defaults.get(CONF_URL, vol.UNDEFINED)): str,
            code(CONF_PAIRING_CODE): PASSWORD,
            vol.Required(CONF_VERIFY_SSL, default=defaults.get(CONF_VERIFY_SSL, True)): bool,
            vol.Optional(CONF_CA_FILE, description={"suggested_value": defaults.get(CONF_CA_FILE)}): str,
        }
    )


def _token_schema(defaults: Mapping[str, Any]) -> vol.Schema:
    return vol.Schema(
        {
            vol.Required(CONF_HOST, default=defaults.get(CONF_HOST, vol.UNDEFINED)): str,
            vol.Required(CONF_PORT, default=defaults.get(CONF_PORT, DEFAULT_PORT)): vol.All(
                vol.Coerce(int), vol.Range(min=1, max=65535)
            ),
            vol.Required(CONF_TOKEN): PASSWORD,
        }
    )


def split_secret(text: str, fallback_urls: list[str]) -> tuple[str, list[str]]:
    """A pairing code and the addresses to try, from either a bare code or a whole link."""
    text = text.strip()
    if text.startswith("meterkat:"):
        link = parse_pairing_link(text)
        return link.code, fallback_urls + [u for u in link.urls if u not in fallback_urls]
    return text, fallback_urls


def error_key(err: Exception) -> str:
    if isinstance(err, MeterkatSslError):
        return "ssl_error"
    if isinstance(err, MeterkatAuthError):
        return "invalid_auth"
    return "cannot_connect"


class MeterkatConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 2

    def __init__(self) -> None:
        self._discovered_url: str | None = None
        self._result: ConfigFlowResult | None = None

    # -- shared steps of work --

    async def _async_ssl(self, user_input: Mapping[str, Any]) -> tuple[SslOption, str | None]:
        data = {CONF_VERIFY_SSL: user_input.get(CONF_VERIFY_SSL, True), CONF_CA_FILE: user_input.get(CONF_CA_FILE)}
        try:
            return await async_ssl_option(self.hass, data), None
        except (OSError, ssl_lib.SSLError):
            return True, "ca_file_unreadable"

    async def _async_check(self, url: str, token: str, ssl: SslOption) -> tuple[dict[str, Any] | None, str | None]:
        """(snapshot, None) when the companion accepts the token, else (None, error key)."""
        client = MeterkatClient(async_get_clientsession(self.hass), url, token, ssl)
        try:
            return await client.async_get_usage(), None
        except (MeterkatAuthError, MeterkatConnectionError) as err:
            LOGGER.debug("Cannot use %s: %r", url, err)
            return None, error_key(err)

    async def _async_redeem(
        self, urls: list[str], code: str, ssl: SslOption
    ) -> tuple[dict[str, Any] | None, str | None]:
        """Pair with the first address that answers: ({"url", "token"}, None) or (None, error key)."""
        session = async_get_clientsession(self.hass)
        error = "cannot_connect"
        for url in urls:
            try:
                health = await async_health(session, url, ssl)
                if not supports_device_tokens(health["version"]):
                    error = "companion_too_old"
                    continue
                result = await async_redeem_code(session, url, code, ssl)
            except MeterkatNotACompanion:
                error = "not_meterkat"
            except MeterkatPairingError:
                return None, "pairing_failed"
            except MeterkatConnectionError as err:
                LOGGER.debug("Pairing through %s failed: %r", url, err)
                if isinstance(err, MeterkatSslError):
                    error = "ssl_error"
            else:
                return {CONF_URL: url, CONF_TOKEN: result.token}, None
        return None, error

    async def _async_pair_and_check(
        self, urls: list[str], secret: str, ssl: SslOption
    ) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str | None]:
        """Redeem a code or link, then confirm the new token works: (entry data, snapshot, error)."""
        try:
            code, urls = split_secret(secret, urls)
        except MeterkatInvalidLink:
            return None, None, "invalid_link"
        data, error = await self._async_redeem(urls, code, ssl)
        if data is None:
            return None, None, error
        snapshot, error = await self._async_check(data[CONF_URL], data[CONF_TOKEN], ssl)
        return (data, snapshot, None) if snapshot is not None else (None, None, error)

    @staticmethod
    def _unique_id(snapshot: Mapping[str, Any]) -> str:
        return str(snapshot.get("companionId") or snapshot.get("host") or "meterkat").lower()

    @staticmethod
    def _is_entry_for(entry: ConfigEntry, snapshot: Mapping[str, Any]) -> bool:
        """Entries made before companion ids existed are keyed by the companion's hostname."""
        ids = {str(snapshot.get("companionId") or "").lower(), str(snapshot.get("host") or "").lower()} - {""}
        return entry.unique_id is not None and entry.unique_id in ids

    async def _async_create(self, snapshot: dict[str, Any], data: dict[str, Any]) -> ConfigFlowResult:
        for entry in self._async_current_entries():
            if self._is_entry_for(entry, snapshot):
                self.hass.config_entries.async_update_entry(entry, data={**entry.data, **data})
                self.hass.config_entries.async_schedule_reload(entry.entry_id)
                return self.async_abort(reason="already_configured")
        await self.async_set_unique_id(self._unique_id(snapshot))
        self._abort_if_unique_id_configured(updates=data)
        host = str(snapshot.get("host") or display_host(data[CONF_URL]))
        return self.async_create_entry(title="Meterkat (%s)" % host, data=data)

    # -- add --

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        return self.async_show_menu(step_id="user", menu_options=["pairing_link", "url", "legacy_token"])

    async def async_step_pairing_link(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                link = parse_pairing_link(user_input[CONF_PAIRING_LINK])
            except MeterkatInvalidLink:
                errors["base"] = "invalid_link"
            else:
                data, snapshot, error = await self._async_pair_and_check(
                    link.urls, user_input[CONF_PAIRING_LINK], True
                )
                if snapshot is not None:
                    return await self._async_create(snapshot, {**data, CONF_VERIFY_SSL: True})
                errors["base"] = error
        return self.async_show_form(step_id="pairing_link", data_schema=LINK_SCHEMA, errors=errors)

    async def async_step_url(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            errors = await self._async_url_attempt(user_input)
            if not errors:
                return self._result
        return self.async_show_form(step_id="url", data_schema=_url_schema(user_input or {}), errors=errors)

    async def _async_url_attempt(self, user_input: Mapping[str, Any]) -> dict[str, str]:
        """Pair through the entered URL. On success, `self._result` holds the flow's next result."""
        try:
            url = normalize_url(user_input[CONF_URL])
        except MeterkatInvalidUrl:
            return {CONF_URL: "invalid_url"}
        ssl, error = await self._async_ssl(user_input)
        if error:
            return {CONF_CA_FILE: error}
        data, snapshot, error = await self._async_pair_and_check([url], user_input[CONF_PAIRING_CODE], ssl)
        if snapshot is None:
            return {"base": error}
        data.update({CONF_VERIFY_SSL: user_input.get(CONF_VERIFY_SSL, True)})
        if user_input.get(CONF_CA_FILE):
            data[CONF_CA_FILE] = user_input[CONF_CA_FILE]
        self._result = await self._async_create(snapshot, data)
        return {}

    async def async_step_legacy_token(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            url = url_from_host_port(user_input[CONF_HOST], user_input[CONF_PORT])
            token = user_input[CONF_TOKEN].strip()
            try:
                await async_health(async_get_clientsession(self.hass), url)
            except MeterkatNotACompanion:
                errors["base"] = "not_meterkat"
            except MeterkatConnectionError as err:
                errors["base"] = error_key(err)
            else:
                snapshot, error = await self._async_check(url, token, True)
                if snapshot is not None:
                    return await self._async_create(snapshot, {CONF_URL: url, CONF_TOKEN: token, CONF_VERIFY_SSL: True})
                errors["base"] = error
        return self.async_show_form(
            step_id="legacy_token", data_schema=_token_schema(user_input or {}), errors=errors
        )

    # -- discovery --

    async def async_step_zeroconf(self, discovery_info: ZeroconfServiceInfo) -> ConfigFlowResult:
        props = discovery_info.properties
        url = url_from_host_port(discovery_info.host, discovery_info.port)
        host = str(props.get("host") or discovery_info.hostname.removesuffix(".").removesuffix(".local"))
        known = {str(props.get("id") or "").lower(), host.lower()} - {""}
        for entry in self._async_current_entries():
            if entry.unique_id is not None and entry.unique_id in known:
                # Follow a changed address, but never replace an HTTPS URL the user chose.
                if entry.data.get(CONF_URL, "").startswith("http://") and entry.data[CONF_URL] != url:
                    self.hass.config_entries.async_update_entry(entry, data={**entry.data, CONF_URL: url})
                return self.async_abort(reason="already_configured")
        if props.get("id"):
            await self.async_set_unique_id(str(props["id"]).lower())
            self._abort_if_unique_id_configured()
        if not supports_device_tokens(props.get("version")):
            return self.async_abort(reason="companion_too_old")
        self._discovered_url = url
        self.context["title_placeholders"] = {"name": host}
        return await self.async_step_zeroconf_confirm()

    async def async_step_zeroconf_confirm(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        assert self._discovered_url
        if user_input is not None:
            data, snapshot, error = await self._async_pair_and_check(
                [self._discovered_url], user_input[CONF_PAIRING_CODE], True
            )
            if snapshot is not None:
                return await self._async_create(snapshot, {**data, CONF_VERIFY_SSL: True})
            errors["base"] = error
        return self.async_show_form(
            step_id="zeroconf_confirm",
            data_schema=CODE_SCHEMA,
            description_placeholders={"name": self.context["title_placeholders"]["name"], "url": self._discovered_url},
            errors=errors,
        )

    # -- reauth and reconfigure --

    async def async_step_reauth(self, entry_data: Mapping[str, Any]) -> ConfigFlowResult:
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        entry = self._get_reauth_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            ssl, error = await self._async_ssl(entry.data)
            data = dict(entry.data)
            snapshot = None
            if error is None and (secret := (user_input.get(CONF_PAIRING_CODE) or "").strip()):
                paired, snapshot, error = await self._async_pair_and_check([data[CONF_URL]], secret, ssl)
                if paired is not None:
                    data.update(paired)
            elif error is None and (token := (user_input.get(CONF_TOKEN) or "").strip()):
                data[CONF_TOKEN] = token
                snapshot, error = await self._async_check(data[CONF_URL], token, ssl)
            elif error is None:
                error = "missing_credentials"
            if snapshot is not None:
                if not self._is_entry_for(entry, snapshot):
                    return self.async_abort(reason="wrong_companion")
                return self.async_update_reload_and_abort(entry, data=data)
            errors["base"] = error
        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=vol.Schema({vol.Optional(CONF_PAIRING_CODE): PASSWORD, vol.Optional(CONF_TOKEN): PASSWORD}),
            description_placeholders={"host": display_host(entry.data[CONF_URL])},
            errors=errors,
        )

    async def async_step_reconfigure(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        """Change the address or TLS settings, or move to a token of its own with a pairing code."""
        entry = self._get_reconfigure_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                url = normalize_url(user_input[CONF_URL])
            except MeterkatInvalidUrl:
                errors[CONF_URL] = "invalid_url"
            else:
                ssl, error = await self._async_ssl(user_input)
                data = {**entry.data, CONF_URL: url, CONF_VERIFY_SSL: user_input.get(CONF_VERIFY_SSL, True)}
                data.pop(CONF_CA_FILE, None)
                if user_input.get(CONF_CA_FILE):
                    data[CONF_CA_FILE] = user_input[CONF_CA_FILE]
                snapshot = None
                if error:
                    errors[CONF_CA_FILE] = error
                elif secret := (user_input.get(CONF_PAIRING_CODE) or "").strip():
                    paired, snapshot, error = await self._async_pair_and_check([url], secret, ssl)
                    if paired is not None:
                        data.update(paired)
                else:
                    snapshot, error = await self._async_check(url, data[CONF_TOKEN], ssl)
                if snapshot is not None:
                    if not self._is_entry_for(entry, snapshot):
                        return self.async_abort(reason="wrong_companion")
                    return self.async_update_reload_and_abort(entry, data=data)
                if error and not errors:
                    errors["base"] = error
        defaults = user_input or entry.data
        return self.async_show_form(
            step_id="reconfigure", data_schema=_url_schema(defaults, code_required=False), errors=errors
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry) -> MeterkatOptionsFlow:
        return MeterkatOptionsFlow()


class MeterkatOptionsFlow(OptionsFlow):
    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            return self.async_create_entry(data={CONF_SCAN_INTERVAL: int(user_input[CONF_SCAN_INTERVAL])})
        current = self.config_entry.options.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL)
        return self.async_show_form(
            step_id="init",
            data_schema=vol.Schema(
                {
                    vol.Required(CONF_SCAN_INTERVAL, default=current): NumberSelector(
                        NumberSelectorConfig(
                            min=MIN_SCAN_INTERVAL,
                            max=MAX_SCAN_INTERVAL,
                            step=1,
                            unit_of_measurement="s",
                            mode=NumberSelectorMode.BOX,
                        )
                    )
                }
            ),
        )
