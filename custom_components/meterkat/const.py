"""Constants for the Meterkat integration."""

from __future__ import annotations

import logging

DOMAIN = "meterkat"
LOGGER = logging.getLogger(__package__)

DEFAULT_PORT = 47300
# What this integration calls itself when it pairs (shown in `meterkat devices`).
CLIENT_NAME = "Home Assistant"
# The first companion release that gives each pairing its own token.
MIN_DEVICE_TOKEN_VERSION = (2, 5, 0)
DEVICE_TOKEN_PREFIX = "mkd_"

CONF_URL = "url"
CONF_VERIFY_SSL = "verify_ssl"
CONF_CA_FILE = "ca_file"
CONF_PAIRING_CODE = "pairing_code"

CONF_PAIRING_LINK = "pairing_link"
CONF_SCAN_INTERVAL = "scan_interval"

# Minimum seconds between two updates. The companion builds a new snapshot
# every 120 s by default, so anything up to that delivers every snapshot.
DEFAULT_SCAN_INTERVAL = 60
MIN_SCAN_INTERVAL = 10
MAX_SCAN_INTERVAL = 3600

# GET /v1/usage?since=... waits up to this long for the next snapshot
# (the companion caps it at MAX_WAIT_SECONDS = 300).
LONG_POLL_WAIT = 300
# Back-off after a failed request, and the polling fallback for companions
# older than 2.3.0, which ignore `since` and answer at once.
RETRY_SECONDS = 30
FALLBACK_POLL_SECONDS = 120

# A provider reading older than this counts as stale even when the companion
# does not flag it (its background poll runs every 120 s).
STALE_AFTER_SECONDS = 15 * 60

STATUS_OK = "ok"
STATUSES = ["ok", "no_plan", "not_signed_in", "error"]
