"""Client for the Meterkat companion's HTTP API."""

from __future__ import annotations

import asyncio
import ssl as ssl_lib
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, urlsplit

import aiohttp

from .const import CLIENT_NAME, DEFAULT_PORT, MIN_DEVICE_TOKEN_VERSION

REQUEST_TIMEOUT = 15
HISTORY_TIMEOUT = 5

# `ssl` for aiohttp: True verifies with the system CAs, False skips verification,
# an SSLContext verifies against a custom CA.
SslOption = bool | ssl_lib.SSLContext


class MeterkatError(Exception):
    """Base error."""


class MeterkatConnectionError(MeterkatError):
    """The companion could not be reached or answered with an error."""


class MeterkatSslError(MeterkatConnectionError):
    """The companion's HTTPS certificate isn't trusted."""


class MeterkatAuthError(MeterkatError):
    """The companion rejected the token."""


class MeterkatPairingError(MeterkatError):
    """The pairing code was expired, already used, or not accepted."""


class MeterkatInvalidLink(MeterkatError):
    """The text is not a meterkat://pair link."""


class MeterkatInvalidUrl(MeterkatError):
    """The text is not an http(s) address."""


class MeterkatNotACompanion(MeterkatError):
    """The address answers, but not like a Meterkat companion."""


class MeterkatTooOld(MeterkatError):
    """The companion is older than the release that pairs devices individually."""

    def __init__(self, version: str) -> None:
        super().__init__(version)
        self.version = version


@dataclass(frozen=True)
class PairingLink:
    """A parsed `meterkat://pair?...` link (see pairing_link() in meterkat.py)."""

    code: str
    urls: list[str]
    name: str | None


@dataclass(frozen=True)
class PairResult:
    token: str
    device_id: str | None


def parse_pairing_link(text: str) -> PairingLink:
    """Parse a pairing link. The LAN address comes first, then the remote one."""
    parts = urlsplit(text.strip())
    if parts.scheme != "meterkat" or (parts.netloc or parts.path.strip("/")) != "pair":
        raise MeterkatInvalidLink
    query = parse_qs(parts.query)
    code = query.get("code", [""])[0]
    urls = [query[key][0].rstrip("/") for key in ("local", "remote") if query.get(key)]
    if not code or not urls:
        raise MeterkatInvalidLink
    return PairingLink(code=code, urls=urls, name=query.get("name", [None])[0])


def normalize_url(text: str) -> str:
    """A companion address as the base URL, without a trailing slash.

    Takes `192.168.1.20`, `box.local:47300` or `https://box.example.ts.net:47300/meterkat`.
    A bare host means a companion on its default port. HTTPS with no port is a reverse
    proxy on 443."""
    text = text.strip()
    if not text:
        raise MeterkatInvalidUrl
    parts = urlsplit(text if "://" in text else "http://" + text)
    try:
        port = parts.port
    except ValueError as err:
        raise MeterkatInvalidUrl from err
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.query or parts.fragment:
        raise MeterkatInvalidUrl
    host = parts.hostname
    if ":" in host:
        host = "[%s]" % host
    if port is None and parts.scheme == "http":
        port = DEFAULT_PORT
    netloc = "%s:%d" % (host, port) if port is not None else host
    return "%s://%s%s" % (parts.scheme, netloc, parts.path.rstrip("/"))


def url_from_host_port(host: str, port: int) -> str:
    host = host.strip()
    if ":" in host and not host.startswith("["):  # IPv6 literal
        host = "[%s]" % host
    return "http://%s:%d" % (host, port)


def display_host(url: str) -> str:
    return urlsplit(url).hostname or url


def version_tuple(version: Any) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in str(version).split(".")[:3])
    except ValueError:
        return ()


def supports_device_tokens(version: Any) -> bool:
    return version_tuple(version) >= MIN_DEVICE_TOKEN_VERSION


async def _json(
    session: aiohttp.ClientSession, method: str, url: str, ssl: SslOption, **kwargs: Any
) -> tuple[int, Any]:
    try:
        async with session.request(
            method, url, ssl=ssl, timeout=aiohttp.ClientTimeout(total=kwargs.pop("total", REQUEST_TIMEOUT)), **kwargs
        ) as resp:
            try:
                body = await resp.json(content_type=None)
            except (ValueError, aiohttp.ContentTypeError):
                body = None
            return resp.status, body
    except aiohttp.ClientSSLError as err:
        raise MeterkatSslError(str(err)) from err
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ssl_lib.SSLError) as err:
        raise MeterkatConnectionError(str(err) or type(err).__name__) from err


async def async_health(session: aiohttp.ClientSession, url: str, ssl: SslOption = True) -> dict[str, Any]:
    """GET /health (no auth). Raises MeterkatNotACompanion when something else answers."""
    status, body = await _json(session, "GET", url + "/health", ssl)
    if status != 200 or not isinstance(body, dict) or not body.get("ok") or "pollSeconds" not in body \
            or not isinstance(body.get("version"), str):
        raise MeterkatNotACompanion
    return body


async def async_redeem_code(
    session: aiohttp.ClientSession, url: str, code: str, ssl: SslOption = True
) -> PairResult:
    """Trade a single-use pairing code for this client's own token (POST /v1/pair)."""
    status, body = await _json(session, "POST", url + "/v1/pair", ssl, json={"code": code, "name": CLIENT_NAME})
    if status in (400, 401):
        raise MeterkatPairingError
    if status == 429:
        raise MeterkatConnectionError("too many attempts, try again in a few minutes")
    if status != 200:
        raise MeterkatConnectionError("HTTP %d" % status)
    token = body.get("token") if isinstance(body, dict) else None
    if not isinstance(token, str) or not token:
        raise MeterkatPairingError
    return PairResult(token=token, device_id=body.get("deviceId"))


class MeterkatClient:
    """Reads GET /v1/usage. Every request carries `since`, so the companion
    answers from its cache and never fetches the providers for us."""

    def __init__(self, session: aiohttp.ClientSession, url: str, token: str, ssl: SslOption = True) -> None:
        self._session = session
        self._url = url + "/v1/usage"
        self._history_url = url + "/v1/history"
        self._headers = {"Authorization": "Bearer " + token}
        self._ssl = ssl

    async def async_get_usage(self, since: str | None = None, wait: float = 0) -> dict[str, Any]:
        """The current snapshot, or with `since` and `wait`, the next one newer
        than `since` (or the current one after `wait` seconds)."""
        # An empty `since` would be dropped by the companion's parse_qs and turn
        # into a plain GET, which can start a provider refresh. "0" never
        # matches a generatedAt, so it returns the cached snapshot at once.
        params = {"since": since or "0", "wait": str(int(wait))}
        status, data = await _json(
            self._session, "GET", self._url, self._ssl,
            params=params, headers=self._headers, total=wait + REQUEST_TIMEOUT,
        )
        if status == 401:
            raise MeterkatAuthError
        if status == 429:
            raise MeterkatConnectionError("locked out after too many bad tokens")
        if status != 200:
            raise MeterkatConnectionError("HTTP %d" % status)
        if not isinstance(data, dict) or not isinstance(data.get("providers"), list):
            raise MeterkatConnectionError("unexpected response")
        return data

    async def async_get_history(self) -> list[dict[str, Any]] | None:
        """GET /v1/history: the current cycle of every window, with the rate projection.

        None when the companion has no history endpoint (older than 2.3.0). It
        never makes the companion fetch from a provider.
        """
        # Short timeout: the usage sensors never wait long on the chart data.
        status, data = await _json(
            self._session, "GET", self._history_url, self._ssl, headers=self._headers, total=HISTORY_TIMEOUT
        )
        if status == 401:
            raise MeterkatAuthError
        if status == 404:
            return None
        if status != 200:
            raise MeterkatConnectionError("HTTP %d" % status)
        series = data.get("series") if isinstance(data, dict) else None
        if not isinstance(series, list):
            raise MeterkatConnectionError("unexpected response")
        return [s for s in series if isinstance(s, dict)]
