#!/usr/bin/env python3
"""meterkat: the Meterkat companion CLI.

Reads the credentials of the already-signed-in Claude Code, Codex, OpenCode,
GitHub (gh / Copilot), Gemini CLI and Cursor tools on this machine (and
OpenRouter / Z.ai / DeepSeek keys), polls the providers' usage
endpoints, and serves a normalized JSON snapshot at GET /v1/usage for the AI
Usage iOS app, plus the usage history of the current windows at GET /v1/history.
GET /v1/pairing (loopback only) returns the pairing link for the Mac app. Each pairing
creates the client's own read-only token (viewer) or, for `meterkat pair --owner`, a
token that can also manage devices (owner). See `meterkat devices`.

Python 3.9+ standard library only. Runs on macOS and Linux.

It never refreshes provider tokens and never writes to the CLIs' credential
stores: refreshing would rotate the refresh token and log the CLI out.
"""

import argparse
import base64
import calendar
import concurrent.futures
import getpass
import hashlib
import hmac
import http.client
import ipaddress
import json
import math
import os
import platform
import plistlib
import re
import secrets
import shutil
import signal
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import api_cost
import devices
import discovery
import qr

VERSION = "2.5.8"
DEFAULT_PORT = 47300
DEFAULT_CACHE_SECONDS = 60
DEFAULT_POLL_SECONDS = 120
MIN_REFRESH_SECONDS = 15
MAX_WAIT_SECONDS = 300  # longest GET /v1/usage?since=... long-poll
REVOKE_CHECK_SECONDS = 5  # a waiting long-poll checks its device still exists this often
RESET_CATCHUP_SECONDS = 300  # after a window's reset time, refetch until its new cycle shows...
RESET_RETRY_SECONDS = 30     # ...at most this often
HTTP_TIMEOUT = 15
COST_SCAN_SECONDS = 300
LAST_GOOD_MAX_AGE = 3600  # serve last good provider data on transient errors
EXPIRED_LAST_GOOD_MAX_AGE = 7 * 86400  # ...and, marked stale, while the CLI's token is expired

CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".config", "meterkat")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

LAUNCHD_LABEL = "com.sahil.meterkat.companion"
LAUNCHD_PLIST = os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents", LAUNCHD_LABEL + ".plist")
LAUNCHD_LOG = os.path.join(os.path.expanduser("~"), "Library", "Logs", "meterkat.log")
SYSTEMD_UNIT_NAME = "meterkat.service"
SYSTEMD_UNIT = os.path.join(os.path.expanduser("~"), ".config", "systemd", "user", SYSTEMD_UNIT_NAME)

# The Meterkat Mac app (built from Mac/ in the repo), opened at login by `meterkat install`.
MENUBAR_LABEL = "com.sahil.meterkat.menubar"
MENUBAR_PLIST = os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents", MENUBAR_LABEL + ".plist")
MAC_APP_PATHS = ["/Applications/Meterkat.app",
                 os.path.join(os.path.expanduser("~"), "Applications", "Meterkat.app")]
# Up to 1.4, `aiusage install` built this menu bar app with swiftc.
LEGACY_MENUBAR_APP = os.path.join(os.path.expanduser("~"), "Applications", "AI Usage Companion.app")

# Before 2.0 the project was called AI Usage and the CLI `aiusage`. `meterkat install` removes
# that install (its service holds the same port) and load_config() copies its config once.
OLD_CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".config", "ai-usage-companion")
OLD_LAUNCHD_LABELS = ["com.aiusage.companion", "com.aiusage.menubar"]
OLD_SYSTEMD_UNIT_NAME = "ai-usage-companion.service"
OLD_MAC_APPS = ["/Applications/AI Usage.app",
                os.path.join(os.path.expanduser("~"), "Applications", "AI Usage.app"),
                LEGACY_MENUBAR_APP]

# `meterkat config set/unset` names -> config.json keys.
URL_KEYS = {"local-url": "localURL", "remote-url": "remoteURL"}
# `meterkat config set-key/unset-key` providers -> config.json keys.
API_KEY_KEYS = {"openrouter": "openrouterKey", "zai": "zaiKey", "copilot": "copilotToken", "deepseek": "deepseekKey"}
LOOPBACK = ("127.0.0.1", "::1", "::ffff:127.0.0.1")

CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
OPENAI_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
OPENCODE_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
OPENROUTER_KEY_URL = "https://openrouter.ai/api/v1/key"
OPENROUTER_CREDITS_URL = "https://openrouter.ai/api/v1/credits"
COPILOT_USER_URL = "https://api.github.com/copilot_internal/user"
GEMINI_LOAD_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
GEMINI_QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
CURSOR_USAGE_URL = "https://cursor.com/api/usage"
CURSOR_STRIPE_URL = "https://cursor.com/api/auth/stripe"
ZAI_QUOTA_URL = "https://api.z.ai/api/monitor/usage/quota/limit"
KIMI_USAGE_URL = "https://api.kimi.com/coding/v1/usages"
MINIMAX_USAGE_BASES = {"global": "https://api.minimax.io", "cn": "https://api.minimax.cn"}
BAILIAN_CODING_PLAN_API = "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"
DEEPSEEK_BALANCE_URL = "https://api.deepseek.com/user/balance"

FIVE_HOURS = 18000
ONE_DAY = 86400
ONE_WEEK = 604800
ONE_MONTH = 2592000

HISTORY_MAX_AGE = 35 * 86400
HISTORY_MAX_POINTS = 20000   # per series
HISTORY_MIN_GAP = 600        # record an unchanged percent at most this often
HISTORY_SERVED_POINTS = 300  # per series in GET /v1/history

IS_MAC = sys.platform == "darwin"


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def log(msg):
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sys.stderr.write("[%s] %s\n" % (stamp, msg))
    sys.stderr.flush()


def iso_utc(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso():
    return iso_utc(datetime.now(timezone.utc))


_ISO_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?$",
    re.IGNORECASE,
)


def normalize_time(value):
    """Return 'YYYY-MM-DDTHH:MM:SSZ' (UTC) from ISO strings or epoch numbers."""
    if value is None or isinstance(value, bool):
        return None
    try:
        if isinstance(value, (int, float)):
            ts = float(value)
            if ts > 1e12:  # milliseconds
                ts /= 1000.0
            return iso_utc(datetime.fromtimestamp(ts, timezone.utc))
        if isinstance(value, str):
            s = value.strip()
            if not s:
                return None
            if re.fullmatch(r"\d+(\.\d+)?", s):
                return normalize_time(float(s))
            m = _ISO_RE.match(s)
            if not m:
                return None
            y, mo, d, h, mi, sec, tz = m.groups()
            dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(sec or 0), tzinfo=timezone.utc)
            if tz and tz.upper() != "Z":
                sign = 1 if tz[0] == "+" else -1
                digits = tz[1:].replace(":", "")
                offset = sign * (int(digits[:2]) * 3600 + int(digits[2:4]) * 60)
                dt = datetime.fromtimestamp(dt.timestamp() - offset, timezone.utc)
            return iso_utc(dt)
    except (ValueError, OverflowError, OSError):
        return None
    return None


def to_float(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def slug(name):
    s = re.sub(r"[^a-z0-9]+", "_", str(name).lower()).strip("_")
    return s or "model"


def short_hostname():
    return socket.gethostname().split(".")[0]


def jwt_claims(token):
    """Decode a JWT payload without verifying it (only used for hints)."""
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part.encode()))
    except Exception:
        return {}


def run_cmd(args, timeout=5):
    try:
        out = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        if out.returncode != 0:
            return None
        return out.stdout.decode("utf-8", "replace")
    except Exception:
        return None


def read_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _ssl_context():
    ctx = ssl.create_default_context()
    # python.org builds on macOS ship without CA certs unless the user ran
    # "Install Certificates"; the system bundle fills that gap.
    for path in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
        if os.path.exists(path):
            try:
                ctx.load_verify_locations(cafile=path)
            except Exception:
                pass
    return ctx


SSL_CONTEXT = _ssl_context()


class ProviderError(Exception):
    def __init__(self, message, status="error", transient=False, rate_limited=False, retry_after=None,
                 http_code=None, body=None):
        super().__init__(message)
        self.status = status
        self.transient = transient
        self.rate_limited = rate_limited
        self.retry_after = retry_after
        self.http_code = http_code
        self.body = body


def http_get_json(url, headers, auth_message, json_body=None):
    """GET `url`, or POST `json_body` as JSON when given. Returns the parsed JSON response."""
    data = None
    if json_body is not None:
        data = json.dumps(json_body).encode("utf-8")
        headers = dict(headers, **{"Content-Type": "application/json"})
    req = urllib.request.Request(url, data=data, headers=headers, method="GET" if data is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=SSL_CONTEXT) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        snippet = ""
        try:
            snippet = e.read().decode("utf-8", "replace").strip()[:200]
        except Exception:
            pass
        if e.code in (401, 403):
            raise ProviderError(auth_message + " (HTTP %d)" % e.code, http_code=e.code, body=snippet)
        if e.code == 429:
            retry = to_float(e.headers.get("Retry-After")) if e.headers else None
            raise ProviderError("Rate limited by provider (HTTP 429); will retry later.",
                                transient=True, rate_limited=True, retry_after=retry)
        raise ProviderError("HTTP %d from %s: %s" % (e.code, urllib.parse.urlsplit(url).netloc, snippet),
                            transient=e.code >= 500, http_code=e.code, body=snippet)
    except urllib.error.URLError as e:
        raise ProviderError("Network error: %s" % getattr(e, "reason", e), transient=True)
    except (socket.timeout, TimeoutError):
        raise ProviderError("Timed out after %ds" % HTTP_TIMEOUT, transient=True)
    except (http.client.HTTPException, OSError) as e:
        # A dropped connection (RemoteDisconnected, IncompleteRead, a reset) isn't wrapped in URLError.
        raise ProviderError("Network error: %s" % (str(e) or type(e).__name__), transient=True)
    try:
        return json.loads(body.decode("utf-8"))
    except Exception:
        raise ProviderError("Provider returned invalid JSON", transient=True)


# Fixed window types, safe to match on (labels are for display and may change).
# `model` is a per-model window; its period is in `windowSeconds`.
WINDOW_KINDS = ("session", "weekly", "daily", "monthly", "model", "credit")


def make_window(wid, kind, label, percent, resets_at, window_seconds):
    assert kind in WINDOW_KINDS, "unknown window kind %r" % kind
    return {
        "id": wid,
        "kind": kind,
        "label": label,
        "percent": round(float(percent), 1) if percent is not None else 0.0,
        "resetsAt": resets_at,
        "windowSeconds": window_seconds,
    }


def provider_result(pid, name, status="ok", plan=None, account=None, error=None, windows=None, fetched=True,
                    details=None, breakdown=None):
    """`details` is a list of (label, value) pairs; it and `breakdown` are left out when empty."""
    result = {
        "id": pid,
        "name": name,
        "plan": plan,
        "account": account,
        "status": status,
        "error": error,
        "fetchedAt": now_iso() if fetched else None,
        "windows": windows or [],
    }
    if details:
        result["details"] = [{"label": label, "value": value} for label, value in details]
    if breakdown:
        result["breakdown"] = breakdown
    return result


CURRENCY_SYMBOLS = {"USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"}


def format_money(amount, currency="USD", places=2):
    code = str(currency or "USD").upper()
    text = "%.*f" % (places, abs(amount))
    symbol = CURRENCY_SYMBOLS.get(code)
    text = symbol + text if symbol else "%s %s" % (text, code)
    return "-" + text if amount < 0 else text


def compact_count(n):
    """136900 -> '136.9k'."""
    for size, suffix in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if n >= size:
            return "%.1f%s" % (n / size, suffix)
    return "%d" % n


def relative_age(seconds):
    seconds = max(0, int(seconds))
    for size, unit in ((86400, "day"), (3600, "hour"), (60, "minute")):
        if seconds >= size:
            n = seconds // size
            return "%d %s%s ago" % (n, unit, "" if n == 1 else "s")
    return "just now"


def humanize(value):
    """'out_of_credits' -> 'out of credits'."""
    return str(value).replace("_", " ").strip()


# --------------------------------------------------------------------------
# Claude
# --------------------------------------------------------------------------

CLAUDE_EXPIRED = "Claude token expired — run `claude` once on this machine to refresh it."


def claude_config_dir():
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    return os.path.expanduser(env) if env else os.path.join(os.path.expanduser("~"), ".claude")


def claude_keychain_services():
    """Keychain items Claude Code may store its credentials under, most specific first."""
    services = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        digest = hashlib.sha256(os.path.expanduser(env).encode()).hexdigest()[:8]
        services.append("Claude Code-credentials-" + digest)
    services.append("Claude Code-credentials")
    return services


def read_claude_credentials():
    """Return the parsed credentials JSON, or None if not signed in."""
    if IS_MAC:
        for service in claude_keychain_services():
            out = run_cmd(["security", "find-generic-password", "-s", service, "-w"], timeout=10)
            if out and out.strip():
                try:
                    return json.loads(out.strip())
                except ValueError:
                    pass
    return read_json_file(os.path.join(claude_config_dir(), ".credentials.json"))


def claude_account_email():
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    candidates = []
    if env:
        candidates.append(os.path.join(os.path.expanduser(env), ".claude.json"))
    candidates.append(os.path.join(os.path.expanduser("~"), ".claude.json"))
    for path in candidates:
        data = read_json_file(path)
        if isinstance(data, dict):
            acct = data.get("oauthAccount")
            if isinstance(acct, dict) and acct.get("emailAddress"):
                return acct["emailAddress"]
    return None


def parse_claude_windows(data):
    windows = []
    seen = set()

    def add(w):
        if w["id"] not in seen:
            seen.add(w["id"])
            windows.append(w)

    limits = data.get("limits")
    if isinstance(limits, list):
        for item in limits:
            if not isinstance(item, dict):
                continue
            kind = item.get("kind")
            pct = to_float(item.get("percent"))
            if pct is None:
                pct = to_float(item.get("utilization"))
            if pct is None:
                continue
            resets = normalize_time(item.get("resets_at"))
            if kind == "session":
                add(make_window("five_hour", "session", "5-hour", pct, resets, FIVE_HOURS))
            elif kind == "weekly_all":
                add(make_window("weekly", "weekly", "Weekly", pct, resets, ONE_WEEK))
            elif kind == "weekly_scoped":
                scope = item.get("scope") if isinstance(item.get("scope"), dict) else {}
                model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
                name = model.get("display_name") or model.get("id")
                if name:
                    add(make_window("weekly_" + slug(name), "model", str(name), pct, resets, ONE_WEEK))

    # Legacy fields: fill anything the limits array didn't cover.
    legacy = [
        ("five_hour", "five_hour", "session", "5-hour", FIVE_HOURS),
        ("seven_day", "weekly", "weekly", "Weekly", ONE_WEEK),
        ("seven_day_opus", "weekly_opus", "model", "Opus", ONE_WEEK),
        ("seven_day_sonnet", "weekly_sonnet", "model", "Sonnet", ONE_WEEK),
    ]
    for key, wid, kind, label, secs in legacy:
        obj = data.get(key)
        if isinstance(obj, dict):
            pct = to_float(obj.get("utilization"))
            if pct is not None:
                add(make_window(wid, kind, label, pct, normalize_time(obj.get("resets_at")), secs))
    return windows


def claude_extra_usage(extra):
    """'Off (out of credits) · $0.00 of $76.26 this month'. Amounts are in minor units."""
    enabled = bool(extra.get("is_enabled"))
    state = "On" if enabled else "Off"
    if extra.get("spend_limit_reached"):
        state += " (limit reached)"
    elif not enabled and extra.get("disabled_reason"):
        state += " (%s)" % humanize(extra["disabled_reason"])
    places = extra.get("decimal_places")
    places = int(places) if to_float(places) is not None else 2
    currency = extra.get("currency") or "USD"

    def money(minor):
        return format_money(minor / 10.0 ** places, currency, places)

    used = to_float(extra.get("used_credits")) or 0.0
    limit = to_float(extra.get("monthly_limit"))
    if limit is not None:
        return "%s · %s of %s this month" % (state, money(used), money(limit))
    if used:
        return "%s · %s this month" % (state, money(used))
    return state


def parse_claude_details(data):
    details = []
    extra = data.get("extra_usage")
    if isinstance(extra, dict):
        details.append(("Extra usage", claude_extra_usage(extra)))
    if data.get("member_dashboard_available") is True:
        details.append(("Team insights", "Available on claude.ai"))
    return details


def parse_claude_breakdown(data):
    """The weekly split by product (Claude Code, chats, Cowork...), when there is usage to split."""
    split = data.get("seven_day_breakdown")
    if not isinstance(split, dict) or not isinstance(split.get("rows"), list):
        return None
    rows = []
    for row in split["rows"]:
        pct = to_float(row.get("percent")) if isinstance(row, dict) else None
        if pct is None or not row.get("key"):
            continue
        rows.append({"key": str(row["key"]), "label": str(row.get("display_name") or row["key"]),
                     "percent": round(pct, 1)})
    if not any(r["percent"] > 0 for r in rows):
        return None
    return {"title": "Weekly usage by product", "window": "weekly",
            "asOf": normalize_time(split.get("as_of")), "rows": rows}


def fetch_claude():
    name = "Claude"
    creds = read_claude_credentials()
    oauth = creds.get("claudeAiOauth") if isinstance(creds, dict) else None
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        return provider_result("claude", name, status="not_signed_in", fetched=False,
                               error="Claude Code is not signed in on this machine — run `claude` and log in.")
    plan = oauth.get("subscriptionType") or None
    account = claude_account_email()
    expires = to_float(oauth.get("expiresAt"))
    if expires and expires / 1000.0 < time.time():
        return provider_result("claude", name, status="error", plan=plan, account=account, error=CLAUDE_EXPIRED)
    headers = {
        "Authorization": "Bearer " + oauth["accessToken"],
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.0",
        "Accept": "application/json",
    }
    data = http_get_json(CLAUDE_USAGE_URL, headers, CLAUDE_EXPIRED)
    if not isinstance(data, dict):
        raise ProviderError("Unexpected response from Claude usage endpoint", transient=True)
    return provider_result("claude", name, plan=plan, account=account, windows=parse_claude_windows(data),
                           details=parse_claude_details(data), breakdown=parse_claude_breakdown(data))


# --------------------------------------------------------------------------
# OpenAI (ChatGPT / Codex)
# --------------------------------------------------------------------------

OPENAI_EXPIRED = "Codex token expired — run `codex` once on this machine to refresh it."


def codex_home():
    env = os.environ.get("CODEX_HOME")
    return os.path.expanduser(env) if env else os.path.join(os.path.expanduser("~"), ".codex")


# Window lengths with a name: slot (also the window id) -> (kind, label, shortest, longest).
OPENAI_SLOTS = {
    "five_hour": ("session", "5-hour", 0, 6 * 3600),
    "daily": ("daily", "Daily", 20 * 3600, 30 * 3600),
    "weekly": ("weekly", "Weekly", 6 * 86400, 8 * 86400),
    "monthly": ("monthly", "Monthly", 28 * 86400, 31 * 86400),
}
# The kind of a window whose length has no name. Clients print the label for it,
# while `model` reads as "weekly" on iPhone and weekly/daily/monthly name a period
# it doesn't have. `watch` stops at the stricter 85% for it, the safe side of a guess.
OPENAI_UNNAMED_KIND = "session"
# Response keys that aren't a new allowance: the parsers read them or they aren't usage.
OPENAI_KNOWN_KEYS = {"rate_limit", "additional_rate_limits", "credits", "code_review_rate_limit",
                     "rate_limit_reset_credits", "spend_control", "model_usage"}
OPENAI_KNOWN_RATE_KEYS = {"primary_window", "secondary_window"}


def openai_slot_for(secs):
    """The named slot for a window length in seconds, or None."""
    for slot, (_, _, shortest, longest) in OPENAI_SLOTS.items():
        if shortest <= secs <= longest:
            return slot
    return None


def openai_length_label(secs):
    """A label from a window's real length: "3-day", "12-hour", "30-minute"."""
    if secs < 60:
        amount, unit = secs, "second"
    elif secs < 3600:
        amount, unit = secs / 60.0, "minute"
    elif secs < 2 * 86400:
        amount, unit = secs / 3600.0, "hour"
    else:
        amount, unit = secs / 86400.0, "day"
    return "%s-%s" % (("%.1f" % amount).rstrip("0").rstrip("."), unit)


def openai_window_from(win, default_slot):
    """Return (slot, pct, resets, secs) for a rate-limit window dict.
    `slot` is None for a length outside OPENAI_SLOTS; a missing length means the default slot."""
    if not isinstance(win, dict):
        return None
    pct = to_float(win.get("used_percent"))
    if pct is None:
        return None
    secs = to_float(win.get("limit_window_seconds"))
    secs = int(secs) if secs is not None and math.isfinite(secs) and secs >= 1 else None
    slot = default_slot if secs is None else openai_slot_for(secs)
    resets = normalize_time(win.get("reset_at"))
    if resets is None and to_float(win.get("reset_after_seconds")) is not None:
        resets = normalize_time(time.time() + float(win["reset_after_seconds"]))
    if secs is None:
        secs = FIVE_HOURS if slot == "five_hour" else ONE_WEEK
    return slot, pct, resets, secs


def openai_window_id(slot, secs, suffix, seen):
    """(id, named) for a window, or (None, named) when one of the same length is already listed.
    A second length in the same slot gets an id from its length, so it isn't dropped."""
    named = slot is not None
    wid = (slot or "window_%d" % secs) + suffix
    if wid in seen and seen[wid] != secs:
        named = False
        wid = "window_%d%s" % (secs, suffix)
    if wid in seen:
        return None, named
    seen[wid] = secs
    return wid, named


def log_new_openai_allowance(data, rate):
    """Log the keys when the response carries a usage-like object the parsers don't read."""
    def looks_new(key, value):
        name = str(key).lower()
        return isinstance(value, dict) and ("used_percent" in value or "limit_window_seconds" in value
                                            or "allowance" in name or "token" in name)

    found = [str(k) for k, v in data.items() if k not in OPENAI_KNOWN_KEYS and looks_new(k, v)]
    found += ["rate_limit.%s" % k for k, v in rate.items() if k not in OPENAI_KNOWN_RATE_KEYS and looks_new(k, v)]
    if found:
        log_shape_once("openai", "allowance-like object (%s)" % ", ".join(sorted(found)), data,
                       once_key="openai:allowance")


def log_unnamed_openai_window(data):
    log_shape_once("openai", "rate-limit window length", data, once_key="openai:window")


def parse_openai_windows(data):
    windows = []
    seen = {}  # window id -> its length in seconds
    rate = data.get("rate_limit") if isinstance(data.get("rate_limit"), dict) else {}
    log_new_openai_allowance(data, rate)
    for key, default_slot in (("primary_window", "five_hour"), ("secondary_window", "weekly")):
        parsed = openai_window_from(rate.get(key), default_slot)
        if not parsed:
            continue
        slot, pct, resets, secs = parsed
        wid, named = openai_window_id(slot, secs, "", seen)
        if not named:
            log_unnamed_openai_window(data)
        if wid is None:
            continue
        if named:
            kind, label = OPENAI_SLOTS[slot][:2]
        else:
            kind = OPENAI_SLOTS[slot][0] if slot else OPENAI_UNNAMED_KIND
            label = openai_length_label(secs)
        windows.append(make_window(wid, kind, label, pct, resets, secs))

    extra = data.get("additional_rate_limits")
    entries = []
    if isinstance(extra, list):
        entries = [(None, e) for e in extra]
    elif isinstance(extra, dict):
        entries = list(extra.items())
    for key, entry in entries:
        try:
            if not isinstance(entry, dict):
                continue
            label = (entry.get("limit_name") or entry.get("display_name") or entry.get("name")
                     or entry.get("model") or entry.get("metered_feature") or key)
            if not label:
                continue
            label = str(label)
            inner = entry.get("rate_limit") if isinstance(entry.get("rate_limit"), dict) else entry
            for wkey, default_slot in (("primary_window", "five_hour"), ("secondary_window", "weekly")):
                parsed = openai_window_from(inner.get(wkey), default_slot)
                if not parsed:
                    continue
                slot, pct, resets, secs = parsed
                wid, named = openai_window_id(slot, secs, "_" + slug(label), seen)
                if not named:
                    log_unnamed_openai_window(data)
                if wid is None:
                    continue
                shown = label if named else "%s %s" % (label, openai_length_label(secs))
                windows.append(make_window(wid, "model", shown, pct, resets, secs))
        except Exception:
            continue
    return windows


def parse_openai_details(data):
    details = []
    rate = data.get("rate_limit") if isinstance(data.get("rate_limit"), dict) else {}
    if rate.get("limit_reached") is True:
        details.append(("Limit reached", "Yes, until the limit resets"))
    credits = data.get("credits")
    if isinstance(credits, dict):
        balance = to_float(credits.get("balance"))
        if credits.get("unlimited"):
            details.append(("Credits", "Unlimited"))
        elif credits.get("has_credits") or balance:
            details.append(("Credits", format_money(balance or 0.0)))
    resets = data.get("rate_limit_reset_credits")
    count = to_float(resets.get("available_count")) if isinstance(resets, dict) else None
    if count and count > 0:
        details.append(("Limit resets available", "%d available" % count))
    review = data.get("code_review_rate_limit")
    if isinstance(review, dict):
        parsed = openai_window_from(review.get("primary_window") or review, "weekly")
        if review.get("limit_reached") is True:
            details.append(("Code review", "Limit reached"))
        elif parsed:
            text = "%.0f%% used" % parsed[1]
            left = _time_left(parsed[2])
            details.append(("Code review", text + (" · resets in %s" % left if left else "")))
    return details


def fetch_openai():
    name = "ChatGPT Codex"
    auth = read_json_file(os.path.join(codex_home(), "auth.json"))
    tokens = auth.get("tokens") if isinstance(auth, dict) else None
    if not isinstance(tokens, dict) or not tokens.get("access_token"):
        msg = "Codex CLI is not signed in with ChatGPT on this machine — run `codex login`."
        if isinstance(auth, dict) and auth.get("OPENAI_API_KEY"):
            msg = "Codex CLI is using an API key; plan usage needs a ChatGPT sign-in (`codex login`)."
        return provider_result("openai", name, status="not_signed_in", error=msg, fetched=False)
    access = tokens["access_token"]
    id_claims = jwt_claims(tokens.get("id_token") or "")
    auth_claims = id_claims.get("https://api.openai.com/auth") if isinstance(id_claims, dict) else None
    account_id = tokens.get("account_id")
    if not account_id and isinstance(auth_claims, dict):
        account_id = auth_claims.get("chatgpt_account_id")
    plan = auth_claims.get("chatgpt_plan_type") if isinstance(auth_claims, dict) else None
    account = id_claims.get("email") if isinstance(id_claims, dict) else None
    exp = to_float(jwt_claims(access).get("exp"))
    if exp and exp < time.time():
        return provider_result("openai", name, status="error", plan=plan, account=account, error=OPENAI_EXPIRED)
    headers = {
        "Authorization": "Bearer " + access,
        "User-Agent": "codex_cli_rs/0.50.0",
        "Accept": "application/json",
    }
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id
    data = http_get_json(OPENAI_USAGE_URL, headers, OPENAI_EXPIRED)
    if not isinstance(data, dict):
        raise ProviderError("Unexpected response from ChatGPT usage endpoint", transient=True)
    return provider_result("openai", name, plan=data.get("plan_type") or plan,
                           account=data.get("email") or account, windows=parse_openai_windows(data),
                           details=parse_openai_details(data))


# --------------------------------------------------------------------------
# OpenCode (Go subscription)
# --------------------------------------------------------------------------

OPENCODE_REJECTED = "OpenCode key rejected — run `opencode auth login`."
OPENCODE_NO_PLAN = ("No OpenCode Go subscription on this key. "
                    "Zen is pay-as-you-go, so there are no limits to track.")

# Normalized response keys (lowercase, alphanumerics only) -> window slot.
OPENCODE_SLOT_NAMES = {
    "rolling": "five_hour", "rollingusage": "five_hour", "rolling5h": "five_hour",
    "fivehour": "five_hour", "5h": "five_hour",
    "weekly": "weekly", "weeklyusage": "weekly", "week": "weekly", "rolling7d": "weekly",
    "monthly": "monthly", "monthlyusage": "monthly", "month": "monthly",
}
OPENCODE_SLOTS = [  # slot, kind, label, default window seconds
    ("five_hour", "session", "5-hour", FIVE_HOURS),
    ("weekly", "weekly", "Weekly", ONE_WEEK),
    ("monthly", "monthly", "Monthly", ONE_MONTH),
]
_opencode_shape_logged = False


def opencode_data_dir():
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(os.path.expanduser(base), "opencode")


def opencode_saved_key(*names):
    """The first of `names` saved as an API key by `opencode auth login`. Reads the old shape
    ({"type": "api", "key": ...}) and the OpenCode 2.1 one, which moved credential fields under
    `metadata`."""
    auth = read_json_file(os.path.join(opencode_data_dir(), "auth.json"))
    if isinstance(auth, dict):
        for name in names:
            entry = auth.get(name)
            if not isinstance(entry, dict):
                continue
            meta = entry.get("metadata") if isinstance(entry.get("metadata"), dict) else {}
            kind = entry.get("type") or meta.get("type")
            key = entry.get("key") or meta.get("key") or meta.get("apiKey")
            if kind in (None, "api") and key:
                return str(key)
    return None


def opencode_api_key(env_var, *names):
    """$env_var, else the first of `names` saved as an API key by `opencode auth login`."""
    env = (os.environ.get(env_var) or "").strip()
    if env:
        return env
    return opencode_saved_key(*names)


def read_opencode_key():
    """$OPENCODE_API_KEY, else the Go (or Zen) API key saved by `opencode auth login`."""
    return opencode_api_key("OPENCODE_API_KEY", "opencode-go", "opencode")


# OpenCode providerID -> name in the local usage details.
OPENCODE_PROVIDER_NAMES = {"opencode": "Zen", "opencode-go": "Go", "openrouter": "OpenRouter"}
OPENCODE_STATS_TTL = 300
_opencode_stats = None  # (monotonic time, details)


def opencode_local_details():
    """Spend and tokens per provider over the last 7 and 30 days, from OpenCode's database.
    Opened read-only; a missing, locked or reshaped database just yields no details."""
    global _opencode_stats
    if _opencode_stats and time.monotonic() - _opencode_stats[0] < OPENCODE_STATS_TTL:
        return _opencode_stats[1]
    path = os.path.join(opencode_data_dir(), "opencode.db")
    details = []
    if os.path.exists(path):
        try:
            details = _opencode_usage_details(path)
        except (sqlite3.Error, ValueError, TypeError) as e:
            log("opencode: cannot read local usage from %s: %s" % (path, e))
            details = _opencode_stats[1] if _opencode_stats else []  # e.g. locked: keep the last read
    _opencode_stats = (time.monotonic(), details)
    return details


def _opencode_usage_details(path):
    now_ms = time.time() * 1000
    week_ms = now_ms - 7 * ONE_DAY * 1000
    conn = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(path), uri=True, timeout=2)
    try:
        since = (int(now_ms - 30 * ONE_DAY * 1000),)
        rows = conn.execute(
            "SELECT time_created, json_extract(data, '$.providerID'), json_extract(data, '$.cost'),"
            " json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),"
            " json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.cache.read'),"
            " json_extract(data, '$.tokens.cache.write')"
            " FROM message WHERE time_created >= ? AND json_valid(data)"
            " AND json_extract(data, '$.role') = 'assistant'", since).fetchall()
        try:
            # OpenCode 2 writes session_message (assistant rows carry cost, tokens and
            # model.providerID). It also copied old v1 messages across with the same id: skip those.
            rows += conn.execute(
                "SELECT time_created, json_extract(data, '$.model.providerID'), json_extract(data, '$.cost'),"
                " json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),"
                " json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.cache.read'),"
                " json_extract(data, '$.tokens.cache.write')"
                " FROM session_message WHERE time_created >= ? AND type = 'assistant' AND json_valid(data)"
                " AND id NOT IN (SELECT id FROM message)", since).fetchall()
        except sqlite3.OperationalError as e:
            if "no such table" not in str(e):  # an older OpenCode has no session_message
                raise
    finally:
        conn.close()
    stats = {}  # providerID -> {"week": [cost, tokens], "month": [cost, tokens], "last": ms}
    for created, provider, cost, *tokens in rows:
        entry = stats.setdefault(provider or "unknown", {"week": [0.0, 0], "month": [0.0, 0], "last": 0})
        cost = to_float(cost) or 0.0
        count = int(sum(to_float(t) or 0 for t in tokens))
        periods = ("week", "month") if created >= week_ms else ("month",)
        for period in periods:
            entry[period][0] += cost
            entry[period][1] += count
        entry["last"] = max(entry["last"], created)
    details = []
    host = short_hostname()
    for provider, entry in sorted(stats.items(), key=lambda item: -item[1]["last"]):
        name = OPENCODE_PROVIDER_NAMES.get(provider) or humanize(provider).title()
        for period, span in (("week", "7 days"), ("month", "30 days")):
            cost, count = entry[period]
            details.append(("%s on %s · %s" % (name, host, span),
                            "%s · %s tokens" % (format_money(cost), compact_count(count))))
    if stats:
        last = max(entry["last"] for entry in stats.values())
        details.append(("Last used", relative_age(time.time() - last / 1000.0)))
    return details


def first_value(obj, *keys):
    for key in keys:
        if obj.get(key) is not None:
            return obj[key]
    return None


def month_before_seconds(resets):
    """Length of the calendar month ending at `resets` (monthly plans renew on a day of the month)."""
    try:
        end = datetime.strptime(resets, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
    year, month = (end.year, end.month - 1) if end.month > 1 else (end.year - 1, 12)
    start = end.replace(year=year, month=month, day=min(end.day, calendar.monthrange(year, month)[1]))
    return int((end - start).total_seconds())


def opencode_window_from(slot, win):
    if not isinstance(win, dict):
        return None
    pct = to_float(first_value(win, "usagePercent", "usage_percent", "percent", "used_percent"))
    if pct is None:
        used = to_float(first_value(win, "usageDollars", "usage_dollars"))
        limit = to_float(first_value(win, "limitDollars", "limit_dollars"))
        if used is None or not limit:
            return None
        pct = used / limit * 100.0
    left = to_float(first_value(win, "resetInSec", "reset_in_sec", "reset_after_seconds"))
    resets = normalize_time(time.time() + left) if left is not None else None
    if resets is None:
        resets = normalize_time(first_value(win, "resetsAt", "resetAt", "resets_at", "reset_at"))
    _, kind, label, secs = next(s for s in OPENCODE_SLOTS if s[0] == slot)
    given = to_float(first_value(win, "windowSeconds", "window_seconds", "limit_window_seconds"))
    if given:
        secs = int(given)
    elif slot == "monthly":
        secs = month_before_seconds(resets) or secs
    return make_window(slot, kind, label, pct, resets, secs)


OPENCODE_MODEL_CONTAINERS = ("models", "byModel", "by_model", "perModel", "per_model", "modelUsage")
OPENCODE_MODEL_NAME_KEYS = ("model", "modelID", "model_id", "modelName", "name", "id")
OPENCODE_PLAN_NAMES = {"go": "go", "goplus": "go plus", "goteams": "go teams", "plus": "go plus",
                       "teams": "go teams", "team": "go teams"}


def parse_opencode_plan(data):
    """"go", "go plus" or "go teams" from the usage response; "go" when it names none of them."""
    if isinstance(data, dict):
        for container in (data, data.get("usage"), data.get("subscription")):
            if isinstance(container, dict):
                for key in ("plan", "planName", "plan_name", "tier"):
                    value = container.get(key)
                    if isinstance(value, dict):
                        value = first_value(value, "name", "id", "type")
                    plan = OPENCODE_PLAN_NAMES.get(re.sub(r"[^a-z0-9]", "", str(value or "").lower()))
                    if plan:
                        return plan
    return "go"


def opencode_slot(name):
    return OPENCODE_SLOT_NAMES.get(re.sub(r"[^a-z0-9]", "", str(name).lower()))


def opencode_model_windows(models):
    """Per-model windows as {model name: {slot: window}}. `models` is a dict keyed by model name or
    a list of entries naming their model; each model holds its windows keyed by name
    ({"rolling": ..., "weekly": ...}) or as a list tagged with window/name/type."""
    if isinstance(models, dict):
        entries = [(name, entry) for name, entry in models.items()]
    elif isinstance(models, list):
        entries = [(first_value(entry, *OPENCODE_MODEL_NAME_KEYS), entry)
                   for entry in models if isinstance(entry, dict)]
    else:
        return {}
    out = {}
    for model, entry in entries:
        if not model or not isinstance(entry, (dict, list)):
            continue
        wins = {}
        if isinstance(entry, dict):
            holder = entry
            for key in ("usage", "limits", "windows"):
                if isinstance(entry.get(key), (dict, list)):
                    holder = entry[key]
                    break
            pairs = list(holder.items()) if isinstance(holder, dict) else \
                [(first_value(w, "window", "type", "name", "id") or "", w) for w in holder if isinstance(w, dict)]
        else:
            pairs = [(first_value(w, "window", "type", "name", "id") or "", w) for w in entry if isinstance(w, dict)]
        for key, win in pairs:
            slot = opencode_slot(key)
            if slot and slot not in wins:
                w = opencode_window_from(slot, win)
                if w:
                    wins[slot] = w
        if wins:
            out[str(model)] = wins
    return out


def parse_opencode_windows(data):
    """Tolerant: the Go usage response isn't documented. The old single-allowance shape is
    {"usage": {"rolling": {"percent", "resetsAt"}, "weekly": ..., "monthly": ...}};
    also accepts window objects keyed by other names (rolling5h, weeklyUsage...)
    at the top level or under usage/limits/windows/data, or a list of them
    tagged with window/name/type. Go limits are now per model (5-hour 20% of the model's monthly
    dollar limit, weekly 50%): windows nested per model (under models/byModel..., or a list of
    entries naming their model) become `model` windows `<slot>_<model>`, and the worst of each slot
    is the headline window (`five_hour`, `weekly`, `monthly`) unless the response gives its own."""
    found = {}

    def add(name, win):
        slot = opencode_slot(name)
        if slot and slot not in found:
            w = opencode_window_from(slot, win)
            if w:
                found[slot] = w

    containers = [data]
    if isinstance(data, dict):
        containers += [data.get(key) for key in ("usage", "limits", "windows", "data")]
    models = {}
    for container in containers:
        if isinstance(container, dict):
            for key, win in container.items():
                add(key, win)
            for key in OPENCODE_MODEL_CONTAINERS:
                for model, wins in opencode_model_windows(container.get(key)).items():
                    models.setdefault(model, wins)
        elif isinstance(container, list):
            for win in container:
                if isinstance(win, dict):
                    add(first_value(win, "window", "name", "type", "id") or "", win)
    headline = []
    per_model = []
    for slot, kind, label, _ in OPENCODE_SLOTS:
        if slot not in found and models:
            worst = max((w[slot] for w in models.values() if slot in w), key=lambda w: w["percent"], default=None)
            if worst:
                found[slot] = make_window(slot, kind, label, worst["percent"], worst["resetsAt"],
                                          worst["windowSeconds"])
        if slot in found:
            headline.append(found[slot])
        for model in sorted(models):
            w = models[model].get(slot)
            if w:
                per_model.append(make_window("%s_%s" % (slot, slug(model)), "model", "%s %s" % (model, label),
                                             w["percent"], w["resetsAt"], w["windowSeconds"]))
    return headline + per_model


def fetch_opencode():
    global _opencode_shape_logged
    name = "OpenCode Go"
    details = opencode_local_details()  # shown whatever the Go subscription says
    key = read_opencode_key()
    if not key:
        return provider_result("opencode", name, status="not_signed_in", fetched=False, details=details,
                               error="OpenCode is not signed in on this machine — run `opencode auth login`.")
    headers = {
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "User-Agent": "meterkat/" + VERSION,
    }
    try:
        data = http_get_json(OPENCODE_USAGE_URL, headers, OPENCODE_REJECTED)
    except ProviderError as e:
        # A Zen-only key: signed in, but pay-as-you-go has no limits.
        if e.http_code == 403 and "EntitlementError" in (e.body or ""):
            return provider_result("opencode", name, status="no_plan", plan="zen", error=OPENCODE_NO_PLAN,
                                   details=details)
        raise
    windows = parse_opencode_windows(data)
    if not windows:
        if not _opencode_shape_logged:
            _opencode_shape_logged = True
            keys = sorted(str(k) for k in data) if isinstance(data, dict) else type(data).__name__
            log("opencode: unrecognised usage response, top-level keys: %s" % (keys,))
        return provider_result("opencode", name, status="error", plan="go", details=details,
                               error="Unrecognised OpenCode usage response")
    return provider_result("opencode", name, plan=parse_opencode_plan(data), windows=windows, details=details)


# --------------------------------------------------------------------------
# OpenRouter
# --------------------------------------------------------------------------

OPENROUTER_REJECTED = ("OpenRouter key rejected — check $OPENROUTER_API_KEY, the key saved with "
                       "`meterkat config set-key openrouter`, or the one saved by `opencode auth login`.")
OPENROUTER_NO_LIMITS = "This OpenRouter key has no limits to track; spend is in the details."
# limit_reset -> the key's usage field for that period.
OPENROUTER_PERIOD_USAGE = {"daily": "usage_daily", "weekly": "usage_weekly", "monthly": "usage_monthly"}


def read_openrouter_key():
    """$OPENROUTER_API_KEY, else the key saved by `meterkat config set-key openrouter`, else the
    OpenRouter API key saved by `opencode auth login`. Re-reads config.json, so a new key applies
    without a restart."""
    env = (os.environ.get("OPENROUTER_API_KEY") or "").strip()
    if env:
        return env
    cfg = read_json_file(CONFIG_PATH)
    saved = cfg.get(API_KEY_KEYS["openrouter"]) if isinstance(cfg, dict) else None
    if isinstance(saved, str) and saved.strip():
        return saved.strip()
    return opencode_api_key("OPENROUTER_API_KEY", "openrouter")


def utc_period_end(period, now=None):
    """(resetsAt, windowSeconds) of the current UTC day, week (from Monday) or month."""
    now = now or datetime.now(timezone.utc)
    day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == "daily":
        return iso_utc(day + timedelta(days=1)), ONE_DAY
    if period == "weekly":
        return iso_utc(day + timedelta(days=7 - day.weekday())), ONE_WEEK
    if period == "monthly":
        days = calendar.monthrange(day.year, day.month)[1]
        return iso_utc(day.replace(day=1) + timedelta(days=days)), days * ONE_DAY
    return None, None


def parse_openrouter(key_data, credits):
    """(windows, details) from GET /key's data and GET /credits' data (None if unavailable)."""
    windows, details = [], []
    free = key_data.get("free_model_daily_requests")
    free = free if isinstance(free, dict) else {}
    used, cap = to_float(free.get("used")), to_float(free.get("limit"))
    if used is not None and cap:
        resets, secs = utc_period_end("daily")
        windows.append(make_window("daily", "daily", "Free requests", used / cap * 100.0, resets, secs))
    limit = to_float(key_data.get("limit"))
    if limit is not None:
        period = key_data.get("limit_reset")
        remaining = to_float(key_data.get("limit_remaining"))
        if remaining is not None:
            spent = limit - remaining  # OpenRouter's own count, BYOK included when the key says so
        else:
            field = OPENROUTER_PERIOD_USAGE.get(period, "usage")
            spent = to_float(key_data.get(field)) or 0.0
            if key_data.get("include_byok_in_limit"):
                spent += to_float(key_data.get("byok_" + field)) or 0.0
        pct = spent / limit * 100.0 if limit > 0 else 100.0
        resets, secs = utc_period_end(period)
        windows.append(make_window("key_limit", "credit", "Key credit limit", pct, resets, secs))

    spend = [(key_data.get(field), span) for field, span in
             (("usage_daily", "today"), ("usage_weekly", "this week"), ("usage_monthly", "this month"))]
    spend = ["%s %s" % (format_money(to_float(v)), span) for v, span in spend if to_float(v) is not None]
    if spend:
        details.append(("Spend", " · ".join(spend)))
    if isinstance(credits, dict):
        total, usage = to_float(credits.get("total_credits")), to_float(credits.get("total_usage"))
        if total is not None and usage is not None:
            details.append(("Credits", "%s left of %s" % (format_money(total - usage), format_money(total))))
    if used is not None and cap:
        details.append(("Free requests", "%d of %d used today" % (used, cap)))
    return windows, details


def fetch_openrouter():
    name = "OpenRouter"
    key = read_openrouter_key()
    if not key:
        return provider_result("openrouter", name, status="not_signed_in", fetched=False,
                               error="No OpenRouter key on this machine — run `meterkat config set-key "
                                     "openrouter` or add OpenRouter with `opencode auth login`.")
    headers = {
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "User-Agent": "meterkat/" + VERSION,
    }
    data = http_get_json(OPENROUTER_KEY_URL, headers, OPENROUTER_REJECTED)
    key_data = data.get("data") if isinstance(data, dict) else None
    if not isinstance(key_data, dict):
        raise ProviderError("Unexpected response from OpenRouter key endpoint", transient=True)
    try:
        credits = http_get_json(OPENROUTER_CREDITS_URL, headers, OPENROUTER_REJECTED).get("data")
    except (ProviderError, AttributeError):
        credits = None  # optional: some keys can't read the account's credits
    windows, details = parse_openrouter(key_data, credits)
    plan = "free" if key_data.get("is_free_tier") else "paid"
    if not windows:
        return provider_result("openrouter", name, status="no_plan", plan=plan, error=OPENROUTER_NO_LIMITS,
                               details=details)
    return provider_result("openrouter", name, plan=plan, windows=windows, details=details)


# --------------------------------------------------------------------------
# Shared by the providers below
# --------------------------------------------------------------------------

_shapes_logged = set()


def log_shape_once(pid, what, data, once_key=None):
    """Log an unrecognised response's top-level keys (never the values), once per provider,
    or once per `once_key` for a provider with separate things to report."""
    key = once_key or pid
    if key in _shapes_logged:
        return
    _shapes_logged.add(key)
    keys = sorted(str(k) for k in data) if isinstance(data, dict) else type(data).__name__
    log("%s: unrecognised %s, top-level keys: %s" % (pid, what, keys))


def saved_api_key(pid):
    """The key saved with `meterkat config set-key <pid>`. Re-reads config.json on every call."""
    cfg = read_json_file(CONFIG_PATH)
    saved = cfg.get(API_KEY_KEYS[pid]) if isinstance(cfg, dict) else None
    return saved.strip() if isinstance(saved, str) and saved.strip() else None


def xdg_config_home():
    return os.path.expanduser(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"))


def add_month(iso):
    """(the same time one calendar month later, seconds between them) for a normalized ISO time."""
    try:
        start = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None, None
    year, month = (start.year, start.month + 1) if start.month < 12 else (start.year + 1, 1)
    end = start.replace(year=year, month=month, day=min(start.day, calendar.monthrange(year, month)[1]))
    return end.strftime("%Y-%m-%dT%H:%M:%SZ"), int((end - start).total_seconds())


# --------------------------------------------------------------------------
# GitHub Copilot (verified against the live endpoint)
# --------------------------------------------------------------------------

COPILOT_REJECTED = "GitHub token rejected — run `gh auth login`."
COPILOT_NO_PLAN = "No Copilot subscription on this GitHub account."
# launchd's PATH is /usr/bin:/bin:/usr/sbin:/sbin, so look where Homebrew puts gh too.
GH_FALLBACK_PATHS = ("/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh")
# quota_snapshots key -> window id, kind, label.
COPILOT_QUOTAS = [
    ("premium_interactions", "monthly", "monthly", "Premium requests"),
    ("chat", "monthly_chat", "model", "Chat"),
    ("completions", "monthly_completions", "model", "Completions"),
]


def gh_binary():
    found = shutil.which("gh")
    if found:
        return found
    return next((p for p in GH_FALLBACK_PATHS if os.access(p, os.X_OK)), None)


def read_github_token():
    """$GH_TOKEN / $GITHUB_TOKEN, the token saved with `meterkat config set-key copilot`,
    `gh auth token`, or the OAuth token of a Copilot editor plugin. Only reads."""
    for var in ("GH_TOKEN", "GITHUB_TOKEN"):
        env = (os.environ.get(var) or "").strip()
        if env:
            return env
    source = github_token_source()
    return source[1] if source else None


def github_token_source():
    """(where, token) for the first GitHub token the service can read, or None. Skips the env vars,
    which the service doesn't see."""
    saved = saved_api_key("copilot")
    if saved:
        return "saved key", saved
    gh = gh_binary()
    if gh:
        out = run_cmd([gh, "auth", "token", "--hostname", "github.com"], timeout=5)
        if out and out.strip():
            return "GitHub CLI (gh)", out.strip()
    directory = os.path.join(xdg_config_home(), "github-copilot")
    for fname in ("apps.json", "hosts.json"):
        data = read_json_file(os.path.join(directory, fname))
        if not isinstance(data, dict):
            continue
        # Keys are "github.com" (hosts.json) or "github.com:<app id>" (apps.json); prefer github.com.
        for _, entry in sorted(data.items(), key=lambda kv: not str(kv[0]).startswith("github.com")):
            if isinstance(entry, dict) and entry.get("oauth_token"):
                return "Copilot editor plugin", str(entry["oauth_token"])
    return None


def copilot_plan(data):
    sku = str(data.get("access_type_sku") or "").lower()
    if "educational" in sku:
        return "education"
    if sku.startswith("free_limited"):
        return "free"
    plan = data.get("copilot_plan")
    # The Max plan (June 2026) isn't seen live; match its name as a whole word in either field.
    if "max" in re.split(r"[^a-z0-9]+", (str(plan or "") + "_" + sku).lower()):
        return "max"
    return plan or (humanize(sku) if sku else None)


COPILOT_CREDIT_USD = 0.01  # 1 GitHub AI Credit = $0.01
COPILOT_METERED = ("Copilot has no included allowance on this account; usage is metered against an "
                   "enterprise budget, so there is nothing to track here.")


def copilot_metered_seat(data):
    """True when the account is on AI Credits with no included allowance (Enterprise $0 seat or Standalone).
    UNPROVEN live: inferred from a token-billed premium_interactions snapshot with entitlement 0 that isn't unlimited."""
    snaps = data.get("quota_snapshots")
    quota = snaps.get("premium_interactions") if isinstance(snaps, dict) else None
    if not isinstance(quota, dict) or quota.get("unlimited") is True:
        return False
    token = data.get("token_based_billing") is True or quota.get("token_based_billing") is True
    total = to_float(quota.get("entitlement"))
    return token and total is not None and total <= 0


def copilot_credits(value):
    return "%d" % value if value == int(value) else "%.1f" % value


def parse_copilot(data):
    """(windows, details) from GET /copilot_internal/user. Unlimited quotas get no window."""
    windows, details = [], []
    resets = normalize_time(first_value(data, "quota_reset_date_utc", "quota_reset_date", "limited_user_reset_date"))
    secs = month_before_seconds(resets)
    snaps = data.get("quota_snapshots")
    if isinstance(snaps, dict):
        for key, wid, kind, label in COPILOT_QUOTAS:
            quota = snaps.get(key)
            if not isinstance(quota, dict) or quota.get("unlimited") is True:
                continue
            total = to_float(quota.get("entitlement"))
            left = to_float(first_value(quota, "remaining", "quota_remaining"))
            pct_left = to_float(quota.get("percent_remaining"))
            if pct_left is not None:
                pct = 100.0 - pct_left
            elif total and left is not None:
                pct = (total - left) / total * 100.0
            else:
                continue
            credits = quota.get("token_based_billing") is True or (
                key == "premium_interactions" and data.get("token_based_billing") is True)
            if credits and key == "premium_interactions":
                label = "AI Credits"
            windows.append(make_window(wid, kind, label, max(0.0, pct), resets, secs))
            if credits and total:
                used = to_float(quota.get("credits_used"))
                if used is None and left is not None:
                    used = total - left
                if used is not None:
                    used = max(0.0, used)
                    details.append((label, "%s of %s used (%s of %s)" % (
                        copilot_credits(used), copilot_credits(total),
                        format_money(used * COPILOT_CREDIT_USD), format_money(total * COPILOT_CREDIT_USD))))
            elif total and left is not None:
                details.append((label, "%d of %d used" % (max(0.0, total - left), total)))
            overage = to_float(quota.get("overage_count"))
            if overage and overage > 0:
                details.append(("%s overage" % label, "%d" % overage))
    else:
        # Older free-plan shape: monthly_quotas (allowance) and limited_user_quotas (remaining).
        allowance = data.get("monthly_quotas") if isinstance(data.get("monthly_quotas"), dict) else {}
        remaining = data.get("limited_user_quotas") if isinstance(data.get("limited_user_quotas"), dict) else {}
        for key, wid, kind, label in COPILOT_QUOTAS[1:]:
            total, left = to_float(allowance.get(key)), to_float(remaining.get(key))
            if total and left is not None:
                windows.append(make_window(wid, kind, label, max(0.0, (total - left) / total * 100.0),
                                           resets, secs))
                details.append((label, "%d of %d used" % (max(0.0, total - left), total)))
    return windows, details


def fetch_copilot():
    name = "GitHub Copilot"
    token = read_github_token()
    if not token:
        return provider_result("copilot", name, status="not_signed_in", fetched=False,
                               error="No GitHub sign-in on this machine — run `gh auth login`.")
    headers = {
        "Authorization": "token " + token,
        "Accept": "application/json",
        "Editor-Version": "vscode/1.99.0",
        "X-Github-Api-Version": "2025-04-01",
        "User-Agent": "meterkat/" + VERSION,
    }
    try:
        data = http_get_json(COPILOT_USER_URL, headers, COPILOT_REJECTED)
    except ProviderError as e:
        if e.http_code == 404:
            return provider_result("copilot", name, status="no_plan", error=COPILOT_NO_PLAN)
        raise
    if not isinstance(data, dict):
        raise ProviderError("Unexpected response from GitHub Copilot endpoint", transient=True)
    if copilot_metered_seat(data):
        return provider_result("copilot", name, plan=copilot_plan(data), account=data.get("login") or None,
                               status="no_plan", error=COPILOT_METERED)
    windows, details = parse_copilot(data)
    return provider_result("copilot", name, plan=copilot_plan(data), account=data.get("login") or None,
                           windows=windows, details=details)


# --------------------------------------------------------------------------
# Gemini CLI
# UNVERIFIED: implemented from the Gemini CLI's public source and community
# reverse-engineering; not yet tested against a live account. Parsing is
# tolerant and an unknown shape reports an error with the keys logged.
# --------------------------------------------------------------------------

GEMINI_EXPIRED = "Gemini token expired — run `gemini` once to refresh it."
GEMINI_UNRECOGNISED = "Unrecognised Gemini quota response"
GEMINI_METADATA = {"ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"}


def gemini_dir():
    return os.path.join(os.path.expanduser("~"), ".gemini")


def gemini_account(creds):
    email = jwt_claims(creds.get("id_token") or "").get("email")
    if email:
        return str(email)
    accounts = read_json_file(os.path.join(gemini_dir(), "google_accounts.json"))
    if isinstance(accounts, dict) and isinstance(accounts.get("active"), str):
        return accounts["active"] or None
    return None


def gemini_project(load):
    project = load.get("cloudaicompanionProject")
    if isinstance(project, dict):
        project = project.get("id") or project.get("name")
    if isinstance(project, str) and project.strip():
        return project.strip()
    for var in ("GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID"):
        if (os.environ.get(var) or "").strip():
            return os.environ[var].strip()
    return None


def gemini_tier(load):
    for key in ("currentTier", "paidTier"):
        tier = load.get(key)
        if isinstance(tier, dict) and (tier.get("name") or tier.get("id")):
            return str(tier.get("name") or tier.get("id"))
        if isinstance(tier, str) and tier:
            return tier
    return None


def parse_gemini_windows(data):
    """retrieveUserQuota {"buckets": [{"remainingFraction", "resetTime", "modelId", "tokenType"}]}
    -> the most-constrained bucket as `daily`, plus one `daily_<model>` window per model.
    Returns [] when no bucket is readable."""
    buckets = data.get("buckets") if isinstance(data, dict) else None
    if not isinstance(buckets, list):
        return []
    parsed = []
    for bucket in buckets:
        if not isinstance(bucket, dict):
            continue
        left = to_float(bucket.get("remainingFraction"))
        if left is None:
            continue
        pct = max(0.0, min(100.0, (1.0 - left) * 100.0))
        parsed.append((pct, normalize_time(bucket.get("resetTime")), bucket.get("modelId")))
    if not parsed:
        return []
    worst = max(parsed, key=lambda p: p[0])
    windows = [make_window("daily", "daily", "Daily requests", worst[0], worst[1], ONE_DAY)]
    seen = {"daily"}
    for pct, resets, model in parsed:
        if not model:
            continue
        wid = "daily_" + slug(model)
        if wid in seen:
            continue
        seen.add(wid)
        windows.append(make_window(wid, "model", str(model), pct, resets, ONE_DAY))
    return windows


def fetch_gemini():
    name = "Gemini CLI"
    path = os.path.join(gemini_dir(), "oauth_creds.json")
    creds = read_json_file(path) if os.path.exists(path) else None
    if not isinstance(creds, dict) or not creds.get("access_token"):
        return provider_result("gemini", name, status="not_signed_in", fetched=False,
                               error="Gemini CLI is not signed in on this machine — sign in with `gemini`.")
    account = gemini_account(creds)
    expiry = to_float(creds.get("expiry_date"))  # epoch milliseconds
    if expiry and expiry / 1000.0 < time.time():
        return provider_result("gemini", name, status="error", account=account, error=GEMINI_EXPIRED)
    headers = {
        "Authorization": "Bearer " + creds["access_token"],
        "Accept": "application/json",
        "User-Agent": "GeminiCLI/meterkat-" + VERSION,
    }
    load = http_get_json(GEMINI_LOAD_URL, headers, GEMINI_EXPIRED, json_body={"metadata": GEMINI_METADATA})
    if not isinstance(load, dict):
        log_shape_once("gemini", "loadCodeAssist response", load)
        return provider_result("gemini", name, status="error", account=account, error=GEMINI_UNRECOGNISED)
    plan = gemini_tier(load)
    project = gemini_project(load)
    if not project:
        log_shape_once("gemini", "loadCodeAssist response (no project)", load)
        return provider_result("gemini", name, status="error", plan=plan, account=account,
                               error="Gemini Code Assist has no project for this account — run `gemini` once.")
    data = http_get_json(GEMINI_QUOTA_URL, headers, GEMINI_EXPIRED, json_body={"project": project})
    windows = parse_gemini_windows(data)
    if not windows:
        log_shape_once("gemini", "quota response", data)
        return provider_result("gemini", name, status="error", plan=plan, account=account,
                               error=GEMINI_UNRECOGNISED)
    return provider_result("gemini", name, plan=plan, account=account, windows=windows)


# --------------------------------------------------------------------------
# Cursor
# UNVERIFIED: implemented from community reverse-engineering of cursor.com's
# dashboard API; not yet tested against a live account. Tolerant parsing.
# --------------------------------------------------------------------------

CURSOR_REJECTED = "Cursor session rejected — sign in to Cursor again."
CURSOR_EXPIRED = "Cursor token expired — open Cursor once to refresh it."
CURSOR_NO_LIMIT = "Cursor reports no included-request limit (usage-based); requests are in the details."
CURSOR_SEALED = "Cursor stores its login encrypted; Meterkat can't read it yet."
CURSOR_SEALED_PREFIX = "cursor-safe-storage:"  # Cursor 3.27+ with authTokenEncryptionAtRest: Electron safeStorage output
CURSOR_KEYS = ("cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType")


def cursor_state_db():
    if IS_MAC:
        base = os.path.join(os.path.expanduser("~"), "Library", "Application Support")
    else:
        base = xdg_config_home()
    return os.path.join(base, "Cursor", "User", "globalStorage", "state.vscdb")


def read_cursor_auth(path):
    """The cursorAuth/* values from Cursor's state database, opened read-only."""
    conn = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(path), uri=True, timeout=2)
    try:
        rows = conn.execute("SELECT key, value FROM ItemTable WHERE key IN (?, ?, ?)", CURSOR_KEYS).fetchall()
    finally:
        conn.close()
    values = {}
    for key, value in rows:
        if isinstance(value, bytes):
            value = value.decode("utf-8", "replace")
        value = str(value or "").strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':  # stored JSON-encoded
            try:
                value = str(json.loads(value))
            except ValueError:
                pass
        if value:
            values[key] = value
    return values


def parse_cursor_usage(data):
    """(windows, details) from GET /api/usage, or None if no model entry is found.
    {"gpt-4": {"numRequests": N, "maxRequestUsage": M | null}, ..., "startOfMonth": ISO}"""
    if not isinstance(data, dict):
        return None
    models = [(k, v) for k, v in data.items() if isinstance(v, dict) and "numRequests" in v]
    if not models:
        return None
    models.sort(key=lambda kv: kv[0] != "gpt-4")  # gpt-4 is Cursor's "premium requests" bucket
    resets, secs = add_month(normalize_time(data.get("startOfMonth")))
    windows, details = [], []
    for index, (key, entry) in enumerate(models):
        used = to_float(entry.get("numRequests")) or 0.0
        cap = to_float(entry.get("maxRequestUsage"))
        if index == 0:
            if cap:
                windows.append(make_window("monthly", "monthly", "Included requests", used / cap * 100.0,
                                           resets, secs))
                details.append(("Included requests", "%d of %d used" % (used, cap)))
            else:
                details.append(("Requests this month", "%d (usage-based)" % used))
        elif cap:
            windows.append(make_window("monthly_" + slug(key), "model", str(key), used / cap * 100.0,
                                       resets, secs))
    return windows, details


def fetch_cursor():
    name = "Cursor"
    path = cursor_state_db()
    not_signed_in = provider_result("cursor", name, status="not_signed_in", fetched=False,
                                    error="Cursor is not signed in on this machine — open Cursor and log in.")
    if not os.path.exists(path):
        return not_signed_in
    try:
        auth = read_cursor_auth(path)
    except sqlite3.Error as e:
        raise ProviderError("Cannot read Cursor's state database: %s" % e, transient=True)
    token = auth.get("cursorAuth/accessToken")
    if not token:
        return not_signed_in
    account = auth.get("cursorAuth/cachedEmail")
    plan = auth.get("cursorAuth/stripeMembershipType")
    if token.startswith(CURSOR_SEALED_PREFIX):  # not a JWT; reading it needs the OS keychain (not supported yet)
        return provider_result("cursor", name, status="error", plan=plan, account=account, error=CURSOR_SEALED)
    claims = jwt_claims(token)
    sub = str(claims.get("sub") or "")
    user_id = sub.split("|")[-1]  # "auth0|user_XXXX" -> "user_XXXX"
    if not user_id:
        return provider_result("cursor", name, status="error", plan=plan, account=account,
                               error="Unrecognised Cursor session token — sign in to Cursor again.")
    exp = to_float(claims.get("exp"))
    if exp and exp < time.time():
        return provider_result("cursor", name, status="error", plan=plan, account=account, error=CURSOR_EXPIRED)
    headers = {
        "Cookie": "WorkosCursorSessionToken=%s%%3A%%3A%s" % (user_id, token),
        "Accept": "application/json",
        "User-Agent": "meterkat/" + VERSION,
    }
    data = http_get_json(CURSOR_USAGE_URL + "?user=" + urllib.parse.quote(user_id, safe=""), headers,
                         CURSOR_REJECTED)
    try:
        stripe = http_get_json(CURSOR_STRIPE_URL, headers, CURSOR_REJECTED)
        if isinstance(stripe, dict) and stripe.get("membershipType"):
            plan = str(stripe["membershipType"])
    except ProviderError:
        pass  # optional: the plan name only
    parsed = parse_cursor_usage(data)
    if parsed is None:
        log_shape_once("cursor", "usage response", data)
        return provider_result("cursor", name, status="error", plan=plan, account=account,
                               error="Unrecognised Cursor usage response")
    windows, details = parsed
    if not windows:
        return provider_result("cursor", name, status="no_plan", plan=plan, account=account,
                               error=CURSOR_NO_LIMIT, details=details)
    return provider_result("cursor", name, plan=plan, account=account, windows=windows, details=details)


# --------------------------------------------------------------------------
# Z.ai GLM Coding Plan
# UNVERIFIED: implemented from community reverse-engineering of the Z.ai
# dashboard API; not yet tested against a live key. Tolerant parsing.
# --------------------------------------------------------------------------

ZAI_REJECTED = ("Z.ai key rejected — check $ZAI_API_KEY, the key saved with `meterkat config set-key zai`, "
                "or the one saved by `opencode auth login`.")


def read_zai_key():
    """$ZAI_API_KEY / $Z_AI_API_KEY, the key saved with `meterkat config set-key zai`, else a Z.ai
    API key saved by `opencode auth login`."""
    for var in ("ZAI_API_KEY", "Z_AI_API_KEY"):
        env = (os.environ.get(var) or "").strip()
        if env:
            return env
    return saved_api_key("zai") or opencode_api_key("ZAI_API_KEY", "zai-coding-plan", "zai",
                                                    "zhipuai-coding-plan")


def _zai_envelope_rejected(payload):
    return isinstance(payload, dict) and str(payload.get("code")) in ("401", "403")


def parse_zai(payload):
    """(windows, details, plan) from the quota/limit response, or None if no limit is readable.
    Accepts {"data": {"limits": [...]}} (with code/success envelope keys) or {"limits": [...]}."""
    data = payload.get("data") if isinstance(payload, dict) and isinstance(payload.get("data"), dict) else payload
    limits = data.get("limits") if isinstance(data, dict) else None
    if not isinstance(limits, list):
        return None
    windows, details, seen = [], [], set()
    for item in limits:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("type") or "").upper()
        total = to_float(item.get("usage"))           # the allowance
        current = to_float(item.get("currentValue"))  # used so far
        pct = to_float(item.get("percentage"))
        if pct is None and total and current is not None:
            pct = current / total * 100.0
        if pct is None:
            continue
        resets = normalize_time(item.get("nextResetTime"))
        if kind == "TOKENS_LIMIT" and "five_hour" not in seen:
            seen.add("five_hour")
            windows.append(make_window("five_hour", "session", "5-hour", pct, resets, FIVE_HOURS))
        elif kind == "TIME_LIMIT" and "monthly" not in seen:
            seen.add("monthly")
            windows.append(make_window("monthly", "monthly", "Tool calls", pct, resets,
                                       month_before_seconds(resets) or ONE_MONTH))
            if total and current is not None:
                details.append(("Tool calls", "%d of %d used" % (current, total)))
    if not windows:
        return None
    plan = first_value(data, "planName", "plan", "level", "packageName")
    return windows, details, (str(plan) if plan else None)


def fetch_zai():
    name = "Z.ai GLM"
    key = read_zai_key()
    if not key:
        return provider_result("zai", name, status="not_signed_in", fetched=False,
                               error="No Z.ai key on this machine — run `meterkat config set-key zai` "
                                     "or add Z.ai with `opencode auth login`.")
    rejected = None
    payload = None
    # Z.ai takes the raw key; retry with a Bearer prefix if that is refused.
    for auth in (key, "Bearer " + key):
        headers = {"Authorization": auth, "Accept": "application/json", "User-Agent": "meterkat/" + VERSION}
        try:
            payload = http_get_json(ZAI_QUOTA_URL, headers, ZAI_REJECTED)
        except ProviderError as e:
            if e.http_code == 401:
                rejected = e
                continue
            raise
        if _zai_envelope_rejected(payload):
            rejected = ProviderError(ZAI_REJECTED)
            continue
        rejected = None
        break
    if rejected is not None:
        raise rejected
    parsed = parse_zai(payload)
    if parsed is None:
        log_shape_once("zai", "quota response", payload)
        return provider_result("zai", name, status="error", error="Unrecognised Z.ai quota response")
    windows, details, plan = parsed
    return provider_result("zai", name, plan=plan, windows=windows, details=details)


# DeepSeek API (available account balance; the API does not expose plan quota windows)
def parse_deepseek_balance(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("balance_infos"), list):
        return None
    details = []
    for item in payload["balance_infos"]:
        if not isinstance(item, dict):
            continue
        currency = item.get("currency")
        balance = item.get("total_balance")
        if isinstance(currency, str) and isinstance(balance, str):
            try:
                amount = float(balance)
            except ValueError:
                continue
            details.append(("Available balance", format_money(amount, currency)))
    return details if details else []


def fetch_deepseek():
    name = "DeepSeek API"
    key = saved_api_key("deepseek") or (os.environ.get("DEEPSEEK_API_KEY") or "").strip()
    if not key:
        return provider_result("deepseek", name, status="not_signed_in", fetched=False,
                               error="No DeepSeek API key — run `meterkat config set-key deepseek`.")
    headers = {"Authorization": "Bearer " + key, "Accept": "application/json",
               "User-Agent": "meterkat/" + VERSION}
    payload = http_get_json(DEEPSEEK_BALANCE_URL, headers, "DeepSeek API key rejected — check the saved key.")
    details = parse_deepseek_balance(payload)
    if details is None:
        log_shape_once("deepseek", "balance response", payload)
        return provider_result("deepseek", name, status="error", error="Unrecognised DeepSeek balance response")
    return provider_result("deepseek", name, plan="API", details=details)


# Kimi Code (Moonshot's subscription coding plan)
def read_kimi_token():
    """Read Kimi Code CLI's OAuth access token without changing its credentials."""
    share_dir = os.path.expanduser(os.environ.get("KIMI_SHARE_DIR") or "~/.kimi")
    credentials = read_json_file(os.path.join(share_dir, "credentials", "kimi-code.json"))
    token = credentials.get("access_token") if isinstance(credentials, dict) else None
    return token.strip() if isinstance(token, str) and token.strip() else None


def _kimi_used_percent(item):
    """Return used percent from the Kimi Code usage API's used/remaining fields."""
    limit = to_float(item.get("limit"))
    used = to_float(item.get("used"))
    if used is None and limit is not None:
        remaining = to_float(item.get("remaining"))
        if remaining is not None:
            used = limit - remaining
    if used is not None and limit is not None and limit > 0:
        return max(0.0, min(100.0, used / limit * 100.0))
    return None


def parse_kimi(payload):
    """Parse Kimi Code's weekly summary and per-window usage limits."""
    if not isinstance(payload, dict):
        return None
    windows, seen = [], set()
    usage = payload.get("usage")
    if isinstance(usage, dict):
        pct = _kimi_used_percent(usage)
        if pct is not None:
            resets = normalize_time(usage.get("reset_at") or usage.get("resetAt"))
            windows.append(make_window("weekly", "weekly", str(usage.get("name") or "Weekly"), pct,
                                       resets, ONE_WEEK))
            seen.add("weekly")
    limits = payload.get("limits")
    if isinstance(limits, list):
        for index, item in enumerate(limits):
            if not isinstance(item, dict):
                continue
            detail = item.get("detail") if isinstance(item.get("detail"), dict) else item
            pct = _kimi_used_percent(detail)
            if pct is None:
                continue
            window = item.get("window") if isinstance(item.get("window"), dict) else {}
            duration = to_float(window.get("duration") or item.get("duration") or detail.get("duration"))
            time_unit = str(window.get("timeUnit") or item.get("timeUnit") or detail.get("timeUnit") or "").upper()
            if duration is None:
                seconds = FIVE_HOURS
            elif "MINUTE" in time_unit:
                seconds = duration * 60
            elif "HOUR" in time_unit:
                seconds = duration * 3600
            elif "DAY" in time_unit:
                seconds = duration * ONE_DAY
            else:
                seconds = duration
            label = str(item.get("name") or item.get("title") or detail.get("name") or
                        ("5-hour" if seconds <= FIVE_HOURS else "Usage"))
            kind = "session" if seconds <= FIVE_HOURS else "model"
            wid = "five_hour" if seconds <= FIVE_HOURS else "kimi_" + slug(label)
            if wid in seen:
                continue
            resets = normalize_time(detail.get("reset_at") or detail.get("resetAt"))
            windows.append(make_window(wid, kind, label, pct, resets, int(seconds)))
            seen.add(wid)
    return windows or None


def fetch_kimi():
    name = "Moonshot Kimi"
    token = read_kimi_token()
    if not token:
        return provider_result("kimi", name, status="not_signed_in", fetched=False,
                               error="Kimi Code CLI is not signed in on this machine — run `kimi` and sign in.")
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json",
               "User-Agent": "meterkat/" + VERSION}
    payload = http_get_json(KIMI_USAGE_URL, headers, "Kimi Code token rejected — run `kimi` to sign in again.")
    windows = parse_kimi(payload)
    if windows is None:
        log_shape_once("kimi", "usage response", payload)
        return provider_result("kimi", name, status="error", error="Unrecognised Kimi Code usage response")
    plan = payload.get("plan") or payload.get("membership")
    return provider_result("kimi", name, plan=str(plan) if plan else "Kimi Code", windows=windows)


# MiniMax Token Plan
def read_minimax_config():
    config_dir = os.path.expanduser(os.environ.get("MMX_CONFIG_DIR") or "~/.mmx")
    path = os.path.join(config_dir, "config.json")
    config = read_json_file(path)
    return config if isinstance(config, dict) else {}


def parse_minimax_quota(payload):
    """Convert MiniMax Token Plan model rows to usage windows.

    MiniMax's count fields have changed meaning across response versions. The
    explicit remaining percentage disambiguates them when present; without it
    the API's legacy meaning is remaining count.
    """
    if not isinstance(payload, dict) or not isinstance(payload.get("model_remains"), list):
        return None
    by_period = {"five_hour": [], "weekly": []}
    for model in payload["model_remains"]:
        if not isinstance(model, dict):
            continue
        label = str(model.get("model_name") or "MiniMax")
        for period, total_key, used_key, reset_key, kind, prefix in (
            ("five_hour", "current_interval_total_count", "current_interval_usage_count",
             "end_time", "session", "five_hour"),
            ("weekly", "current_weekly_total_count", "current_weekly_usage_count",
             "weekly_end_time", "weekly", "weekly"),
        ):
            total = to_float(model.get(total_key))
            reported = to_float(model.get(used_key))
            remaining_pct = to_float(model.get("current_interval_remaining_percent" if period == "five_hour"
                                               else "current_weekly_remaining_percent"))
            if total is None or total <= 0 or reported is None or reported < 0 or reported > total:
                continue
            remaining_count = reported
            if remaining_pct is not None:
                reported_as_remaining = reported / total * 100.0
                reported_as_used = (total - reported) / total * 100.0
                if min(abs(reported_as_remaining - remaining_pct), abs(reported_as_used - remaining_pct)) > 1:
                    continue
                if abs(reported_as_used - remaining_pct) < abs(reported_as_remaining - remaining_pct):
                    remaining_count = total - reported
            used_percent = max(0.0, min(100.0, (total - remaining_count) / total * 100.0))
            resets = normalize_time(model.get(reset_key))
            by_period[period].append((label, used_percent, resets, kind,
                                      FIVE_HOURS if period == "five_hour" else ONE_WEEK))
    windows = []
    for period, entries in by_period.items():
        if not entries:
            continue
        wid = period
        highest = max(entries, key=lambda entry: entry[1])
        aggregate_label = ("5-hour" if period == "five_hour" else "Weekly")
        windows.append(make_window(wid, highest[3], aggregate_label, highest[1], highest[2], highest[4]))
        if len(entries) > 1:
            for label, percent, resets, kind, seconds in entries:
                windows.append(make_window(period + "_" + slug(label), kind,
                                           label if period == "five_hour" else label + " weekly",
                                           percent, resets, seconds))
    return windows or None


def fetch_minimax():
    name = "MiniMax"
    cfg = read_minimax_config()
    oauth = cfg.get("oauth") if isinstance(cfg.get("oauth"), dict) else {}
    token = oauth.get("access_token") or cfg.get("api_key")
    if not isinstance(token, str) or not token.strip():
        return provider_result("minimax", name, status="not_signed_in", fetched=False,
                               error="MiniMax CLI is not signed in on this machine — run `mmx auth login`.")
    token = token.strip()
    region = oauth.get("region") or cfg.get("region") or "global"
    base_url = (cfg.get("base_url") or oauth.get("resource_url") or
                MINIMAX_USAGE_BASES.get(region, MINIMAX_USAGE_BASES["global"])).rstrip("/")
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json",
               "User-Agent": "meterkat/" + VERSION}
    if token.startswith("sk-api-"):
        payload = http_get_json(base_url + "/account/query_balance", headers,
                                "MiniMax API key rejected — check `~/.mmx/config.json`.")
        if not isinstance(payload, dict) or "available_amount" not in payload:
            log_shape_once("minimax", "account balance response", payload)
            return provider_result("minimax", name, status="error", error="Unrecognised MiniMax balance response")
        balance = payload.get("available_amount")
        return provider_result("minimax", name, status="no_plan", plan="API",
                               details=[("Available balance", str(balance))] if balance is not None else [])
    payload = http_get_json(base_url + "/v1/token_plan/remains", headers,
                            "MiniMax token rejected — run `mmx auth login` to refresh it.")
    if isinstance(payload, dict) and isinstance(payload.get("base_resp"), dict):
        if to_float(payload["base_resp"].get("status_code")) not in (None, 0):
            raise ProviderError("MiniMax rejected the credentials: " +
                                str(payload["base_resp"].get("status_msg") or "request failed"))
    windows = parse_minimax_quota(payload)
    if windows is None:
        log_shape_once("minimax", "Token Plan quota response", payload)
        return provider_result("minimax", name, status="error", error="Unrecognised MiniMax quota response")
    return provider_result("minimax", name, plan="Token Plan", windows=windows)


# Alibaba Cloud Model Studio Coding Plan (Qwen, GLM, Kimi, MiniMax, and others)
def _bailian_credentials():
    config_dir = os.path.expanduser(os.environ.get("BAILIAN_CONFIG_DIR") or "~/.bailian")
    config = read_json_file(os.path.join(config_dir, "config.json"))
    return (config if isinstance(config, dict) else {}), config_dir


def _bailian_api_response(payload):
    """Find the Coding Plan response nested in the console gateway envelope."""
    current = payload
    for _ in range(5):
        if not isinstance(current, dict):
            return None
        if "codingPlanInstanceInfos" in current:
            return current
        current = current.get("data") or current.get("Data") or current.get("result") or current.get("Result")
    return None


def _bailian_window(quota, prefix):
    if not isinstance(quota, dict):
        return None
    used = to_float(quota.get(prefix + "UsedQuota"))
    total = to_float(quota.get(prefix + "TotalQuota"))
    if used is None or total is None or total <= 0:
        return None
    return max(0.0, min(100.0, used / total * 100.0)), normalize_time(quota.get(prefix + "QuotaNextRefreshTime"))


def parse_bailian_coding_plan(payload):
    response = _bailian_api_response(payload)
    if response is None:
        return None, None
    instances = response.get("codingPlanInstanceInfos")
    if not isinstance(instances, list):
        return None, None
    instance = next((row for row in instances if isinstance(row, dict) and row.get("status") == "VALID"), None)
    if instance is None:
        return [], None
    quota = instance.get("codingPlanQuotaInfo")
    if not isinstance(quota, dict):
        return None, instance
    windows = []
    for prefix, wid, kind, label, duration in (
        ("per5Hour", "five_hour", "session", "5-hour", FIVE_HOURS),
        ("perWeek", "weekly", "weekly", "Weekly", ONE_WEEK),
        ("perBillMonth", "monthly", "monthly", "Monthly", ONE_MONTH),
    ):
        parsed = _bailian_window(quota, prefix)
        if parsed is not None:
            percent, resets = parsed
            windows.append(make_window(wid, kind, label, percent, resets, duration))
    return windows, instance


def fetch_bailian_coding_plan():
    name = "Alibaba Coding Plan"
    cfg, _ = _bailian_credentials()
    token = cfg.get("access_token")
    if not isinstance(token, str) or not token.strip():
        return provider_result("bailian", name, status="not_signed_in", fetched=False,
                               error="Bailian CLI console login not found — run `bl auth login --console`.")
    region = str(cfg.get("console_region") or "cn-beijing")
    site = str(cfg.get("console_site") or "domestic")
    gateways = {
        ("cn-beijing", "domestic"): ("bailian-cs.console.aliyun.com", "BroadScopeAspnGateway"),
        ("cn-beijing", "international"): ("bailian-cs.console.alibabacloud.com", "BroadScopeAspnGateway"),
        ("ap-southeast-1", "domestic"): ("modelstudio-cs.console.aliyun.com", "IntlBroadScopeAspnGateway"),
        ("ap-southeast-1", "international"): ("bailian-singapore-cs.alibabacloud.com", "IntlBroadScopeAspnGateway"),
    }
    host, action = gateways.get((region, site), gateways[("cn-beijing", "domestic")])
    data = {
        "queryCodingPlanInstanceInfoRequest": {
            "commodityCode": "sfm_codingplan_public_intl" if site == "international" else "sfm_codingplan_public_cn",
            "onlyLatestOne": True,
        },
        "cornerstoneParam": {
            "protocol": "V2", "console": "ONE_CONSOLE", "productCode": "p_efm",
            "switchUserType": 3, "consoleSite": "BAILIAN_ALIYUN",
        },
    }
    if isinstance(cfg.get("console_switch_agent"), int):
        data["cornerstoneParam"]["switchAgent"] = cfg["console_switch_agent"]
    params = json.dumps({"Api": BAILIAN_CODING_PLAN_API, "V": "1.0", "Data": data})
    url = "https://%s/cli/api.json?%s" % (
        host, urllib.parse.urlencode({"action": action, "product": "sfm_bailian", "api": BAILIAN_CODING_PLAN_API}))
    body = urllib.parse.urlencode({"params": params, "region": region}).encode("utf-8")
    headers = {"Authorization": "Bearer " + token.strip(), "Accept": "application/json",
               "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "meterkat/" + VERSION}
    try:
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT, context=SSL_CONTEXT) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return provider_result("bailian", name, status="error",
                                   error="Bailian console session expired — run `bl auth login --console`.")
        raise ProviderError("HTTP %d from %s" % (error.code, host), transient=error.code >= 500,
                            http_code=error.code)
    except urllib.error.URLError as error:
        raise ProviderError("Network error: %s" % getattr(error, "reason", error), transient=True)
    except (socket.timeout, TimeoutError):
        raise ProviderError("Timed out after %ds" % HTTP_TIMEOUT, transient=True)
    except (http.client.HTTPException, OSError) as error:
        raise ProviderError("Network error: %s" % (str(error) or type(error).__name__), transient=True)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ProviderError("Bailian returned invalid JSON", transient=True)
    windows, instance = parse_bailian_coding_plan(payload)
    if windows is None:
        log_shape_once("bailian", "Coding Plan quota response", payload)
        return provider_result("bailian", name, status="error", error="Unrecognised Coding Plan response")
    if not windows:
        return provider_result("bailian", name, status="no_plan", plan="Coding Plan",
                               error="No active Alibaba Coding Plan subscription was found.")
    plan = instance.get("instanceType") if isinstance(instance, dict) else None
    return provider_result("bailian", name, plan=str(plan or "Coding Plan"), windows=windows)


# --------------------------------------------------------------------------
# History
# --------------------------------------------------------------------------

def history_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(os.path.expanduser(base), "meterkat", "history.json")


def cost_ledger_path():
    return os.path.join(os.path.dirname(history_path()), "costs.json")


def epoch_seconds(iso):
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def downsample(points, limit):
    """At most `limit` points: keeps the first and last, and the peak of each bucket between."""
    if len(points) <= limit:
        return points
    middle = points[1:-1]
    buckets = limit - 2
    size = len(middle) / float(buckets)
    result = [points[0]]
    for i in range(buckets):
        chunk = middle[int(i * size):int((i + 1) * size)]
        if chunk:
            result.append(max(chunk, key=lambda p: p[1]))
    result.append(points[-1])
    return result


class History:
    """Per-window usage points ({"provider|window": [[epoch, percent], ...]}) kept on disk."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.series = self._load()

    def _load(self):
        if not os.path.exists(self.path):
            return {}
        data = read_json_file(self.path)
        raw = data.get("series") if isinstance(data, dict) else None
        if not isinstance(raw, dict):
            log("history: ignoring unreadable %s" % self.path)
            return {}
        series = {}
        for key, points in raw.items():
            if not isinstance(points, list):
                continue
            clean = []
            for point in points:
                if isinstance(point, list) and len(point) == 2:
                    t, pct = to_float(point[0]), to_float(point[1])
                    if t is not None and pct is not None:
                        clean.append([int(t), pct])
            series[str(key)] = clean
        return series

    def record(self, snapshot):
        """Append each ok window's percent when it changed or HISTORY_MIN_GAP passed; save once.
        Points are stamped with the provider's fetchedAt, so last good data
        re-served during an outage or 429 backoff is never recorded as new."""
        now = int(time.time())
        changed = False
        with self.lock:
            for provider in snapshot.get("providers") or []:
                fetched = epoch_seconds(provider.get("fetchedAt"))
                if provider.get("status") != "ok" or fetched is None:
                    continue
                t = int(fetched)
                for w in provider.get("windows") or []:
                    pct = to_float(w.get("percent"))
                    if pct is None:
                        continue
                    points = self.series.setdefault("%s|%s" % (provider.get("id"), w.get("id")), [])
                    if points and (t <= points[-1][0] or
                                   points[-1][1] == pct and t - points[-1][0] < HISTORY_MIN_GAP):
                        continue
                    points.append([t, pct])
                    changed = True
            if changed:
                self._prune(now)
                self._save()

    def _prune(self, now):
        cutoff = now - HISTORY_MAX_AGE
        for key in list(self.series):
            points = [p for p in self.series[key] if p[0] >= cutoff][-HISTORY_MAX_POINTS:]
            if points:
                self.series[key] = points
            else:
                del self.series[key]

    def _save(self):
        directory = os.path.dirname(self.path)
        tmp = self.path + ".tmp"
        try:
            os.makedirs(directory, exist_ok=True)
            os.chmod(directory, 0o700)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump({"version": 1, "series": self.series}, f, separators=(",", ":"))
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except OSError as e:
            log("history: cannot write %s: %s" % (self.path, e))

    def points(self, provider, window, since):
        with self.lock:
            return [list(p) for p in self.series.get("%s|%s" % (provider, window), []) if p[0] >= since]


def history_payload(history, snapshot, provider=None, window=None):
    """GET /v1/history: the current cycle of every window in the snapshot, ending at now."""
    now = int(time.time())
    series = []
    for p in snapshot.get("providers") or []:
        if provider and p.get("id") != provider:
            continue
        for w in p.get("windows") or []:
            if window and w.get("id") != window:
                continue
            resets, secs = w.get("resetsAt"), to_float(w.get("windowSeconds"))
            end = epoch_seconds(resets)
            since = end - secs if end is not None and secs else now - 86400
            points = history.points(p.get("id"), w.get("id"), since) if history else []
            pct = to_float(w.get("percent"))
            if p.get("status") == "ok" and not p.get("stale") and pct is not None:
                if points and points[-1][0] >= now:
                    points[-1] = [now, pct]
                else:
                    points.append([now, pct])
            prediction = usage_prediction(w, points, now) if p.get("status") == "ok" and not p.get("stale") and pct is not None else None
            series.append({
                "provider": p.get("id"),
                "window": w.get("id"),
                "resetsAt": resets,
                "windowSeconds": w.get("windowSeconds"),
                "points": downsample(points, HISTORY_SERVED_POINTS),
                "prediction": prediction,
            })
    return {"generatedAt": now_iso(), "series": series}


def usage_prediction(window, points, now):
    """Project usage from the last 5% of the window, with a cycle-average fallback."""
    resets = epoch_seconds(window.get("resetsAt"))
    seconds = to_float(window.get("windowSeconds"))
    current = to_float(window.get("percent"))
    if resets is None or seconds is None or seconds <= 0 or current is None or resets <= now:
        return None
    start = resets - seconds
    span = seconds * 0.05
    recent = sorted((float(x), float(y)) for x, y in points
                    if len(xy := (x, y)) == 2 and x >= max(start, now - span) and x <= now)
    use_trend = len(recent) >= 2 and recent[-1][0] - recent[0][0] >= span * 0.25
    if use_trend:
        mean_x = sum(x for x, _ in recent) / len(recent)
        mean_y = sum(y for _, y in recent) / len(recent)
        variance = sum((x - mean_x) ** 2 for x, _ in recent)
        rate = sum((x - mean_x) * (y - mean_y) for x, y in recent) / variance if variance else 0.0
        basis = "recent_trend"
    else:
        elapsed = now - start
        if elapsed <= 0:
            return None
        rate = current / elapsed
        basis = "window_average"
    rate = max(rate, 0.0)
    remaining = resets - now
    seconds_to_limit = (100.0 - current) / rate if current < 100 and rate > 0 else None
    runs_out = now + seconds_to_limit if seconds_to_limit is not None and seconds_to_limit < remaining else None
    return {
        "current": current,
        "ratePerHour": rate * 3600.0,
        "projectedAtReset": current + rate * remaining,
        "runsOutAt": normalize_time(runs_out) if runs_out is not None else None,
        "basis": basis,
        "trendMinutes": span / 60.0,
    }


# --------------------------------------------------------------------------
# Snapshot + cache
# --------------------------------------------------------------------------

PROVIDERS = [
    ("claude", "Claude", fetch_claude),
    ("openai", "ChatGPT Codex", fetch_openai),
    ("opencode", "OpenCode Go", fetch_opencode),
    ("openrouter", "OpenRouter", fetch_openrouter),
    ("copilot", "GitHub Copilot", fetch_copilot),
    ("gemini", "Gemini CLI", fetch_gemini),
    ("cursor", "Cursor", fetch_cursor),
    ("zai", "Z.ai GLM", fetch_zai),
    ("kimi", "Moonshot Kimi", fetch_kimi),
    ("minimax", "MiniMax", fetch_minimax),
    ("bailian", "Alibaba Coding Plan", fetch_bailian_coding_plan),
    ("deepseek", "DeepSeek API", fetch_deepseek),
]
PROVIDER_IDS = [pid for pid, _, _ in PROVIDERS]


def disabled_providers(cfg=None):
    """Provider ids turned off with `meterkat config disable`. Re-reads config.json unless given one."""
    if cfg is None:
        cfg = read_json_file(CONFIG_PATH)
    ids = cfg.get("disabledProviders") if isinstance(cfg, dict) else None
    return {pid for pid in ids if pid in PROVIDER_IDS} if isinstance(ids, list) else set()


# --------------------------------------------------------------------------
# Detection: which providers this machine can track, without network calls
# --------------------------------------------------------------------------

def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


def _env_hint(pid, *variables):
    """A hint for a key that's only in this shell, which the background service can't read."""
    var = next((v for v in variables if (os.environ.get(v) or "").strip()), None)
    if not var:
        return None
    return "$%s is set in this shell, but the background service can't read it. Save it as a key." % var


def _detect_claude():
    if IS_MAC:
        for service in claude_keychain_services():
            # Without -w this only checks that the item exists, so there's no Keychain prompt.
            if run_cmd(["security", "find-generic-password", "-s", service], timeout=5) is not None:
                return "macOS Keychain", None
    path = os.path.join(claude_config_dir(), ".credentials.json")
    creds = read_json_file(path)
    oauth = creds.get("claudeAiOauth") if isinstance(creds, dict) else None
    if isinstance(oauth, dict) and oauth.get("accessToken"):
        return tilde(path), None
    return None, "Run `claude` and log in."


def _detect_openai():
    path = os.path.join(codex_home(), "auth.json")
    auth = read_json_file(path)
    tokens = auth.get("tokens") if isinstance(auth, dict) else None
    if isinstance(tokens, dict) and tokens.get("access_token"):
        return tilde(path), None
    if isinstance(auth, dict) and auth.get("OPENAI_API_KEY"):
        return None, "Codex CLI uses an API key. Plan usage needs `codex login` with ChatGPT."
    return None, "Run `codex login` with ChatGPT."


def _detect_opencode():
    if opencode_saved_key("opencode-go", "opencode"):
        return "OpenCode (opencode auth login)", None
    return None, _env_hint("opencode", "OPENCODE_API_KEY") or "Run `opencode auth login` with an OpenCode Go key."


def _detect_openrouter():
    if saved_api_key("openrouter"):
        return "saved key", None
    if opencode_saved_key("openrouter"):
        return "OpenCode (opencode auth login)", None
    return None, _env_hint("openrouter", "OPENROUTER_API_KEY") or "Add an OpenRouter API key."


def _detect_copilot():
    source = github_token_source()
    if source:
        return source[0], None
    return None, _env_hint("copilot", "GH_TOKEN", "GITHUB_TOKEN") or "Run `gh auth login`, or add a GitHub token."


def _detect_gemini():
    path = os.path.join(gemini_dir(), "oauth_creds.json")
    creds = read_json_file(path)
    if isinstance(creds, dict) and creds.get("access_token"):
        return tilde(path), None
    return None, "Run `gemini` and sign in with Google."


def _detect_cursor():
    path = cursor_state_db()
    if os.path.exists(path):
        try:
            token = read_cursor_auth(path).get("cursorAuth/accessToken")
            if token and token.startswith(CURSOR_SEALED_PREFIX):
                return None, CURSOR_SEALED  # signed in, but nothing to poll with: don't offer to enable it
            if token:
                return "Cursor app", None
        except sqlite3.Error:
            pass
    return None, "Open Cursor and log in."


def _detect_zai():
    if saved_api_key("zai"):
        return "saved key", None
    if opencode_saved_key("zai-coding-plan", "zai", "zhipuai-coding-plan"):
        return "OpenCode (opencode auth login)", None
    return None, _env_hint("zai", "ZAI_API_KEY", "Z_AI_API_KEY") or "Add a Z.ai GLM Coding Plan key."


def _detect_kimi():
    path = os.path.join(os.path.expanduser(os.environ.get("KIMI_SHARE_DIR") or "~/.kimi"),
                        "credentials", "kimi-code.json")
    credentials = read_json_file(path)
    if isinstance(credentials, dict) and credentials.get("access_token"):
        return tilde(path), None
    return None, "Run `kimi` and sign in to Kimi Code."


def _detect_minimax():
    cfg = read_minimax_config()
    oauth = cfg.get("oauth") if isinstance(cfg.get("oauth"), dict) else {}
    if oauth.get("access_token") or cfg.get("api_key"):
        config_dir = os.path.expanduser(os.environ.get("MMX_CONFIG_DIR") or "~/.mmx")
        return tilde(os.path.join(config_dir, "config.json")), None
    return None, "Run `mmx auth login` to sign in to MiniMax."


def _detect_bailian_coding_plan():
    cfg, config_dir = _bailian_credentials()
    if cfg.get("access_token"):
        return tilde(os.path.join(config_dir, "config.json")), None
    return None, "Run `bl auth login --console` to sign in to Alibaba Model Studio."


DETECTORS = {
    "claude": _detect_claude,
    "openai": _detect_openai,
    "opencode": _detect_opencode,
    "openrouter": _detect_openrouter,
    "copilot": _detect_copilot,
    "gemini": _detect_gemini,
    "cursor": _detect_cursor,
    "zai": _detect_zai,
    "kimi": _detect_kimi,
    "minimax": _detect_minimax,
    "bailian": _detect_bailian_coding_plan,
    "deepseek": lambda: ("saved key", None) if saved_api_key("deepseek") else (None, _env_hint("deepseek", "DEEPSEEK_API_KEY") or "Add a DeepSeek API key."),
}


def detect_providers(cfg):
    """For each provider: whether the service can find credentials (`source` says where), a `hint`
    when it can't, whether it's enabled, and whether it takes a key from `config set-key`. Reads
    local files only; never prints or returns a secret."""
    disabled = disabled_providers(cfg)
    result = []
    for pid, name, _ in PROVIDERS:
        try:
            source, hint = DETECTORS[pid]()
        except Exception as e:  # one unreadable file mustn't hide the rest
            source, hint = None, "Couldn't check: %s" % e
        result.append({
            "id": pid,
            "name": name,
            "found": bool(source),
            "source": source,
            "hint": hint,
            "enabled": pid not in disabled,
            "takesKey": pid in API_KEY_KEYS,
            "savedKey": bool(cfg.get(API_KEY_KEYS[pid])) if pid in API_KEY_KEYS else False,
        })
    return result


def cmd_detect(args, cfg):
    providers = detect_providers(cfg)
    if args.json:
        print(json.dumps({"version": VERSION, "providers": providers}, indent=2))
        return 0
    for p in providers:
        state = "" if p["enabled"] else " (disabled)"
        if p["found"]:
            print("  found    %-15s %s%s" % (p["name"], p["source"], state))
        else:
            print("  missing  %-15s %s%s" % (p["name"], p["hint"], state))
    return 0


def without_providers(snapshot, disabled):
    if not disabled:
        return snapshot
    return dict(snapshot, providers=[p for p in snapshot.get("providers") or [] if p.get("id") not in disabled])


EXPIRED_TOKEN_ERRORS = (CLAUDE_EXPIRED, OPENAI_EXPIRED, GEMINI_EXPIRED, CURSOR_EXPIRED)


def reset_pending(snapshot, now):
    """True while a window's reset time passed in the last RESET_CATCHUP_SECONDS, so the
    snapshot still shows the old cycle (providers can lag their own reset by a minute or more)."""
    return any(now - RESET_CATCHUP_SECONDS <= t <= now for t in _reset_times(snapshot))


def next_reset(snapshot, now):
    """Epoch of the soonest reset still ahead, or None."""
    return min((t for t in _reset_times(snapshot) if t > now), default=None)


def _reset_times(snapshot):
    for provider in (snapshot or {}).get("providers") or []:
        if provider.get("status") != "ok" or provider.get("stale"):
            continue
        for w in provider.get("windows") or []:
            t = epoch_seconds(w.get("resetsAt"))
            if t is not None:
                yield t


class Poller:
    """Fetches snapshots, caches them, and shields the provider APIs."""

    def __init__(self, cache_seconds=DEFAULT_CACHE_SECONDS, history=None):
        self.cache_seconds = max(0, cache_seconds)
        self.history = history  # records every snapshot built, if set
        self.lock = threading.Lock()          # guards snapshot + snapshot_time
        self.updated = threading.Condition(self.lock)  # notified when a new snapshot is stored
        self.refresh_lock = threading.Lock()  # one provider fetch at a time
        self.state_lock = threading.Lock()    # guards refreshing
        self.refreshing = False
        self.poll_seconds = 0  # set by start_polling; /health reports it for `meterkat watch`
        self.snapshot = None
        self.snapshot_time = 0.0
        self.last_good = {}   # provider id -> (monotonic time, result)
        self.backoff_until = {}  # provider id -> monotonic time
        self.cost_cache = {}
        self.cost_cache_time = 0.0
        self.cost_scanning = False  # guarded by state_lock
        self.cost_files = {}  # parsed log files, kept between scans

    def _fetch_one(self, pid, name, fn):
        result = self._fetch_result(pid, name, fn)
        # Keep the account on failures so the phone still matches this
        # machine to the same login on other computers.
        good = self.last_good.get(pid)
        if not result.get("account") and result.get("status") != "not_signed_in" and good:
            result = dict(result, account=good[1].get("account"))
        return result

    def _fetch_result(self, pid, name, fn):
        now = time.monotonic()
        if self.backoff_until.get(pid, 0) > now:
            good = self.last_good.get(pid)
            if good and now - good[0] < LAST_GOOD_MAX_AGE:
                return good[1]
            return provider_result(pid, name, status="error", error="Rate limited by provider; retrying shortly.")
        try:
            result = fn()
        except ProviderError as e:
            if e.rate_limited:
                self.backoff_until[pid] = now + max(e.retry_after or 0, 120)
            good = self.last_good.get(pid)
            if e.transient and good and now - good[0] < LAST_GOOD_MAX_AGE:
                log("%s: %s (serving last good data)" % (pid, e))
                return good[1]
            log("%s: %s" % (pid, e))
            return provider_result(pid, name, status=e.status, error=str(e))
        except Exception as e:  # never let one provider break the snapshot
            log("%s: unexpected error: %r" % (pid, e))
            return provider_result(pid, name, status="error", error="Companion error: %s" % e)
        if result.get("status") == "ok":
            self.last_good[pid] = (now, result)
        elif result.get("error") in EXPIRED_TOKEN_ERRORS:
            # CLIs renew their token only when next used, so an idle one expires
            # while it still works. Keep the last limits, marked stale; their
            # old fetchedAt keeps them out of the history.
            good = self.last_good.get(pid)
            if good and now - good[0] < EXPIRED_LAST_GOOD_MAX_AGE:
                return dict(good[1], stale=True, error=result["error"])
        return result

    def scan_costs_in_background(self):
        """Reading the CLIs' logs takes minutes on a busy machine, so it never holds up
        plan usage: snapshots carry the last estimate, and a finished scan patches the
        current snapshot."""
        if self.cost_cache_time and time.monotonic() - self.cost_cache_time < COST_SCAN_SECONDS:
            return
        with self.state_lock:
            if self.cost_scanning:
                return
            self.cost_scanning = True

        def run():
            try:
                estimate = api_cost.estimates(ledger_path=cost_ledger_path(), caches=self.cost_files)
                with self.lock:
                    self.cost_cache = estimate
                    self.cost_cache_time = time.monotonic()
                    if self.snapshot is not None:
                        # A copy: handlers may be serializing the old one.
                        self.snapshot = dict(self.snapshot, providers=[
                            dict(p, apiCost=estimate[p["id"]]) if estimate.get(p.get("id")) else p
                            for p in self.snapshot.get("providers") or []])
            except Exception as e:  # local logs must never break plan usage
                log("api cost: scan failed: %r" % e)
                with self.lock:
                    self.cost_cache_time = time.monotonic()  # retry after the usual wait
            finally:
                with self.state_lock:
                    self.cost_scanning = False

        try:
            threading.Thread(target=run, name="cost-scan", daemon=True).start()
        except RuntimeError:
            with self.state_lock:
                self.cost_scanning = False

    def build(self):
        # Re-read config.json each time so `meterkat config disable/enable` applies without a restart.
        disabled = disabled_providers()
        active = [p for p in PROVIDERS if p[0] not in disabled]
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(active))) as pool:
            futures = [pool.submit(self._fetch_one, pid, name, fn) for pid, name, fn in active]
            providers = [f.result() for f in futures]
        self.scan_costs_in_background()
        for provider in providers:
            provider.setdefault("stale", False)
            estimate = self.cost_cache.get(provider["id"])
            if estimate:
                provider["apiCost"] = estimate
        snapshot = {
            "generatedAt": now_iso(),
            "host": short_hostname(),
            "companionVersion": VERSION,
            "providers": providers,
        }
        if self.history is not None:
            try:
                self.history.record(snapshot)
            except Exception as e:  # history must never break the snapshot
                log("history: record failed: %r" % e)
        return snapshot

    def get(self, force=False):
        """Returns the cached snapshot. A stale one is served immediately
        while a background refresh runs, so clients (the phone tries its LAN
        route with a short timeout) never wait on a slow provider. Only the
        very first fetch and ?refresh=1 block."""
        if not force:
            with self.lock:
                if self.snapshot is not None:
                    age = time.monotonic() - self.snapshot_time
                    if age >= self.cache_seconds:
                        self.refresh_in_background()
                    elif age >= RESET_RETRY_SECONDS and reset_pending(self.snapshot, time.time()):
                        self.refresh_in_background(RESET_RETRY_SECONDS)
                    return self.snapshot
        return self._refresh(min_age=MIN_REFRESH_SECONDS if force else self.cache_seconds)

    def refresh_in_background(self, min_age=None):
        min_age = self.cache_seconds if min_age is None else min_age
        with self.state_lock:
            if self.refreshing:
                return
            self.refreshing = True

        def run():
            try:
                self._refresh(min_age=min_age)
            finally:
                with self.state_lock:
                    self.refreshing = False

        threading.Thread(target=run, name="snapshot-refresh", daemon=True).start()

    def start_polling(self, interval):
        """Refresh every `interval` seconds even with no clients, so the history keeps growing."""
        if interval <= 0:
            return
        self.poll_seconds = interval
        # Skip a round when a client just refreshed; never hit providers more than every 15 s.
        min_age = max(MIN_REFRESH_SECONDS, min(interval, self.cache_seconds))

        def run():
            while True:
                time.sleep(self._poll_delay(interval))
                try:
                    with self.lock:
                        catching_up = reset_pending(self.snapshot, time.time())
                    self._refresh(min_age=RESET_RETRY_SECONDS if catching_up else min_age)
                except Exception as e:
                    log("poll failed: %r" % e)

        threading.Thread(target=run, name="snapshot-poll", daemon=True).start()

    def _poll_delay(self, interval):
        """`interval`, but wake just after the next reset, and every RESET_RETRY_SECONDS
        until the providers report the new cycle."""
        now = time.time()
        with self.lock:
            snapshot = self.snapshot
        if reset_pending(snapshot, now):
            return min(interval, RESET_RETRY_SECONDS)
        upcoming = next_reset(snapshot, now)
        if upcoming is not None and upcoming - now < interval:
            return max(1.0, upcoming - now + 2)
        return interval

    def _refresh(self, min_age):
        with self.refresh_lock:
            # Another caller may have refreshed while we waited for the lock.
            with self.lock:
                if self.snapshot is not None and time.monotonic() - self.snapshot_time < min_age:
                    return self.snapshot
            snapshot = self.build()
            with self.lock:
                self.snapshot = snapshot
                self.snapshot_time = time.monotonic()
                self.updated.notify_all()
            return snapshot

    def wait_newer(self, since, timeout):
        """Returns the cached snapshot once its generatedAt differs from
        `since`, or the current one after `timeout` seconds. Never starts a
        provider fetch, so watchers ride on the background poll."""
        deadline = time.monotonic() + max(0.0, timeout)
        with self.lock:
            while self.snapshot is None or self.snapshot.get("generatedAt") == since:
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.updated.wait(left)
            snapshot = self.snapshot
        return snapshot if snapshot is not None else self.get()


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def load_config():
    if not os.path.exists(CONFIG_PATH) and os.path.isdir(OLD_CONFIG_DIR):
        # Keeps the token, saved keys, and disabled providers from the `aiusage` install.
        shutil.copytree(OLD_CONFIG_DIR, CONFIG_DIR, dirs_exist_ok=True)
    cfg = read_json_file(CONFIG_PATH)
    if not isinstance(cfg, dict):
        if os.path.exists(CONFIG_PATH):
            # Never replace a hand-edited file: that would drop the token and overrides.
            sys.exit("meterkat: %s is not a readable JSON object; fix it or delete it for a new token."
                     % CONFIG_PATH)
        cfg = {}
    changed = False
    if not cfg.get("token"):
        cfg["token"] = secrets.token_urlsafe(24)
        changed = True
    if not isinstance(cfg.get("port"), int):
        cfg["port"] = DEFAULT_PORT
        changed = True
    if not cfg.get("companionId"):
        cfg["companionId"] = secrets.token_hex(6)  # stable name for Home Assistant and discovery
        changed = True
    if changed:
        save_config(cfg)
    return cfg


def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass
    # The running service adds paired devices to this file; keep what it wrote.
    with devices.file_lock(CONFIG_PATH):
        devices.write_config(CONFIG_PATH, devices.keep_service_keys(CONFIG_PATH, cfg))


# --------------------------------------------------------------------------
# Terminal output
# --------------------------------------------------------------------------

BOLD, DIM, RED, GREEN, YELLOW, CYAN = 1, 2, 31, 32, 33, 36


def use_color():
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"


def paint(text, *codes):
    """`text` in ANSI styles when stdout is a color terminal, unchanged otherwise."""
    if not codes or not use_color():
        return text
    return "\033[%sm%s\033[0m" % (";".join(str(c) for c in codes), text)


def fit(text, width):
    return text if len(text) <= width else text[:max(width - 1, 0)] + "\u2026"


# --------------------------------------------------------------------------
# Pairing
# --------------------------------------------------------------------------

def tailscale_binary():
    found = shutil.which("tailscale")
    if found:
        return found
    app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    return app if os.path.exists(app) else None


def tailscale_hosts():
    """Return (ipv4 list, MagicDNS name or None)."""
    ts = tailscale_binary()
    ips = []
    dns = None
    out = run_cmd([ts, "ip", "-4"], timeout=5) if ts else None
    if out:
        ips = [line.strip() for line in out.splitlines() if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", line.strip())]
    out = run_cmd([ts, "status", "--json"], timeout=5) if ts else None
    if out:
        try:
            status = json.loads(out)
            self_node = status.get("Self") or {}
            dns = (self_node.get("DNSName") or "").rstrip(".") or None
            if not ips:
                ips = [ip for ip in self_node.get("TailscaleIPs") or [] if ":" not in ip]
        except Exception:
            pass
    if not ips:
        # The Mac App Store build's bundled CLI refuses to run outside an
        # interactive session (e.g. under launchd), but the tailnet address
        # is still on an interface.
        ips = [ip for ip in interface_ipv4s() if _is_tailscale_ip(ip)]
    return ips, dns


def _is_tailscale_ip(ip):
    try:
        a, b = [int(x) for x in ip.split(".")[:2]]
        return a == 100 and 64 <= b <= 127
    except Exception:
        return False


def interface_ipv4s():
    """Every IPv4 address configured on this machine's interfaces."""
    out = run_cmd(["ip", "-4", "-o", "addr", "show"]) if not IS_MAC else None
    if not out:
        out = run_cmd([shutil.which("ifconfig") or "/sbin/ifconfig"])
    return re.findall(r"inet (?:addr:)?(\d+\.\d+\.\d+\.\d+)", out or "")


def lan_ipv4s():
    ips = []
    # Default-route interface first; 10/8 is often routed through a VPN.
    for target in (("8.8.8.8", 80), ("10.255.255.255", 1)):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(target)
            ips.append(s.getsockname()[0])
            s.close()
        except Exception:
            pass
    ips += interface_ipv4s()
    result = []
    for ip in ips:
        # Public addresses are not LAN: the token would cross the internet in plain HTTP.
        if ip.startswith("127.") or ip.startswith("169.254.") or ip == "0.0.0.0" or _address_kind(ip) != "local":
            continue
        if ip not in result:
            result.append(ip)
    return result


def _address_kind(host):
    """'remote' for Tailscale and public addresses, 'local' for LAN ones (like the app's isRemoteAddress)."""
    host = host.lower()
    if host.endswith(".ts.net") or _is_tailscale_ip(host):
        return "remote"
    if host.endswith(".local") or "." not in host:
        return "local"
    try:
        return "local" if ipaddress.ip_address(host).is_private else "remote"
    except ValueError:
        return "remote"


def normalize_base_url(raw):
    """Add http:// when there is no scheme and strip trailing slashes (like CompanionConfig)."""
    if not isinstance(raw, str) or not raw.strip():
        return None
    value = raw.strip()
    if "://" not in value:
        value = "http://" + value
    return value.rstrip("/")


def mask_token(token):
    return "%s...%s" % (token[:4], token[-4:]) if len(token) > 12 else "****"


def pairing_link(code, local=None, remote=None, name=None):
    """`name` (this machine's hostname) becomes the client's name in the iPhone app."""
    parts = ["%s=%s" % (key, urllib.parse.quote(value, safe=""))
             for key, value in (("local", local), ("remote", remote), ("name", name)) if value]
    parts.append("code=" + urllib.parse.quote(code, safe=""))
    return "meterkat://pair?" + "&".join(parts)


CANDIDATES_TTL = 30
_candidates_cache = {}  # (port, bind_host) -> (monotonic time, candidates)
PAIRING_CODE_TTL = 300


class PairingCodes:
    """Short-lived, single-use bootstrap codes held only in companion memory.

    A code has a role: "viewer" (the default) or "owner" (`meterkat pair --owner`)."""
    def __init__(self):
        self._codes = {}
        self._lock = threading.Lock()

    def issue(self, token, role="viewer"):
        code = secrets.token_urlsafe(24)
        with self._lock:
            now = time.monotonic()
            self._codes = {key: value for key, value in self._codes.items() if value[0] > now}
            self._codes[code] = (now + PAIRING_CODE_TTL, token, role)
        return code

    def peek_role(self, code):
        """The role a live code would grant, without using it up; None when it's unknown or expired."""
        with self._lock:
            entry = self._codes.get(code)
            if entry and entry[0] > time.monotonic():
                return entry[2]
        return None

    def redeem_with_role(self, code):
        """Uses the code up: (shared token, role), or None."""
        with self._lock:
            entry = self._codes.pop(code, None)
            if entry and entry[0] > time.monotonic():
                return entry[1], entry[2]
        return None

    def redeem(self, code):
        redeemed = self.redeem_with_role(code)
        return redeemed[0] if redeemed else None


def pairing_candidates(port, bind_host="0.0.0.0"):
    """Addresses the phone may reach us on, Tailscale first: [{label, kind, url}]."""
    cached = _candidates_cache.get((port, bind_host))
    if cached and time.monotonic() - cached[0] < CANDIDATES_TTL:
        return cached[1]
    cands = []  # (label, kind, host)
    if bind_host not in ("0.0.0.0", "", "::"):
        cands.append(("Bound address", _address_kind(bind_host), bind_host))
    else:
        ts_ips, ts_dns = tailscale_hosts()
        for ip in ts_ips:
            cands.append(("Tailscale IP", "remote", ip))
        if ts_dns:
            cands.append(("Tailscale MagicDNS", "remote", ts_dns))
        for ip in lan_ipv4s():
            cands.append(("LAN", "local", ip))
        if not cands:
            cands.append(("Hostname", "local", short_hostname() + ".local"))
    result = []
    for label, kind, host in cands:
        if ":" in host:  # IPv6 literal
            host = "[%s]" % host
        result.append({"label": label, "kind": kind, "url": "http://%s:%d" % (host, port)})
    _candidates_cache[(port, bind_host)] = (time.monotonic(), result)
    return result


def pairing_info(cfg, port, bind_host="0.0.0.0", pairing_codes=None, role="viewer"):
    """The GET /v1/pairing payload. config.json localURL/remoteURL override detection."""
    cands = pairing_candidates(port, bind_host)

    def pick(key, kind):
        override = normalize_base_url(cfg.get(key))
        if override:
            return override
        return next((c["url"] for c in cands if c["kind"] == kind), None)

    local = pick("localURL", "local")
    remote = pick("remoteURL", "remote")
    host = short_hostname()
    return {
        "host": host,
        "port": port,
        "version": VERSION,
        "local": local,
        "remote": remote,
        "role": role,
        "link": pairing_link(pairing_codes.issue(cfg["token"], role) if pairing_codes else secrets.token_urlsafe(24), local, remote, host),
        "candidates": cands,
    }


def print_pairing(cfg, port, bind_host="0.0.0.0", every_address=True, pairing_codes=None, info=None):
    external_info = info is not None
    codes = pairing_codes or PairingCodes()
    info = info or pairing_info(cfg, port, bind_host, codes)
    role = info.get("role", "viewer")
    print("")
    print(paint("Pair your iPhone" if role == "viewer" else "Owner pairing link", BOLD))
    if role == "owner":
        print(paint("  Whoever redeems this link can see this machine's paired devices and revoke them.", YELLOW))
        print(paint("  It works once, for 5 minutes. Share it only with a device you own.", YELLOW))
    print("")
    rows = [
        ("Name", info["host"], "the client's name in the app"),
        ("Local network", info["local"] or "none found", None),
        ("Remote", info["remote"] or "none (install Tailscale, or `meterkat config set remote-url URL`)", None),
        ("Token", mask_token(cfg["token"]), tilde(CONFIG_PATH)),
        ("Companion", "%s, port %d" % (VERSION, port), None),
    ]
    for label, value, note in rows:
        print("  %-14s %s%s" % (label, value, paint("  (%s)" % note, DIM) if note else ""))
    print("")
    print("Pairing link:")
    print("  %s" % info["link"])
    if every_address and len(info["candidates"]) > 1:
        print("")
        print("Every address found, to pair with just one:")
        for c in info["candidates"]:
            print("  %-19s %-7s %s" % (c["label"], c["kind"], c["url"]))
            if not external_info:
                one = pairing_link(codes.issue(cfg["token"], role), name=info["host"], **{c["kind"]: c["url"]})
                print(paint("  %-19s %s" % ("", one), DIM))
    print("")
    if sys.stdout.isatty():
        print(qr.render(info["link"]))
        print("")
        print("Scan the code with the iPhone Camera, or in the Meterkat app: Settings > Clients >")
        print("Add client > Scan QR code. It's added as %s." % paint(info["host"], BOLD))
    else:
        print("Run `meterkat pair` in a terminal to show the QR code, or open the link on the iPhone.")
    print("")
    sys.stdout.flush()
    return info


# --------------------------------------------------------------------------
# HTTP server
# --------------------------------------------------------------------------

_headless_cache = (0.0, None)


def machine_info():
    """{"platform": "macos"|"linux", "headless": bool}. A Linux machine is headless when none of
    its login sessions is a graphical one (the service itself has no DISPLAY on a desktop either)."""
    global _headless_cache
    if IS_MAC:
        return {"platform": "macos", "headless": False}
    when, cached = _headless_cache
    if cached is None or time.monotonic() - when > 60:
        headless = True
        sessions = run_cmd(["loginctl", "list-sessions", "--no-legend"])
        if sessions is None:
            headless = not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
        else:
            for line in sessions.splitlines():
                parts = line.split()
                kind = run_cmd(["loginctl", "show-session", parts[0], "-p", "Type", "--value"]) if parts else None
                if (kind or "").strip() in ("x11", "wayland", "mir"):
                    headless = False
                    break
        cached = headless
        _headless_cache = (time.monotonic(), cached)
    return {"platform": "linux" if sys.platform.startswith("linux") else sys.platform, "headless": cached}


PROXY_HEADERS = ("X-Forwarded-For", "Forwarded", "X-Real-IP", "Tailscale-User-Login")
PAIR_NAME_MAX = 200  # bytes of "name" we'll look at in a pairing request


def is_local_request(handler):
    """True for a request from this machine itself. Anything that arrived through a reverse
    proxy (`tailscale serve`, nginx) comes from 127.0.0.1 too, but names its real source in a header."""
    return handler.client_address[0] in LOOPBACK and not any(handler.headers.get(h) for h in PROXY_HEADERS)


def source_address(handler):
    """The client's address for lockouts and audit lines: behind a local reverse proxy, the first
    X-Forwarded-For hop (anyone who can reach 127.0.0.1 could already forge it)."""
    ip = handler.client_address[0]
    forwarded = handler.headers.get("X-Forwarded-For") if ip in LOOPBACK else None
    return forwarded.split(",")[0].strip() or ip if forwarded else ip


class Principal:
    """Who a request is: the shared token (older apps, the host's own CLI) or a paired device."""

    def __init__(self, kind, device=None, local=False):
        self.kind = kind  # "shared" or "device"
        self.device = device
        self.local = local

    @property
    def role(self):
        return self.device["role"] if self.device else "shared"

    @property
    def label(self):
        return 'device %s "%s"' % (self.device["id"], self.device["name"]) if self.device else "the shared token"

    @property
    def can_manage_devices(self):
        """Owner devices anywhere; the shared token only from this machine."""
        if self.device:
            return self.device["role"] == "owner"
        return self.local


def make_handler(poller, cfg, port, bind_host, pairing_codes=None, store=None, guard=None):
    expected = ("Bearer " + cfg["token"]).encode()
    pairing_codes = pairing_codes or PairingCodes()
    store = store or devices.DeviceStore(CONFIG_PATH)
    guard = guard or devices.AuthGuard()

    class Handler(BaseHTTPRequestHandler):
        server_version = "MeterkatCompanion/" + VERSION
        sys_version = ""

        def log_message(self, fmt, *args):
            log("%s %s" % (self.client_address[0], fmt % args))

        def _send_json(self, code, obj, headers=None):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            if code == 401:
                self.send_header("WWW-Authenticate", 'Bearer realm="meterkat"')
            self.end_headers()
            self.wfile.write(body)

        def _principal(self):
            """The caller, or None. Marks the shared token or device as active."""
            header = (self.headers.get("Authorization") or "").strip()
            local = is_local_request(self)
            if hmac.compare_digest(header.encode(), expected):
                store.touch("shared")
                return Principal("shared", local=local)
            if header[:7].lower() == "bearer ":
                device = store.authenticate(header[7:].strip())
                if device:
                    store.touch(device["id"])
                    return Principal("device", device, local=local)
            return None

        def _authenticate(self):
            """The caller, or None after sending 401 (or 429 while this address is locked out)."""
            ip = source_address(self)
            exempt = is_local_request(self)
            wait = 0 if exempt else guard.retry_after(ip)
            if wait:
                self._send_json(429, {"error": "too_many_attempts"}, {"Retry-After": str(wait)})
                return None
            principal = self._principal()
            if principal is None:
                if not exempt:
                    guard.fail(ip)
                self._send_json(401, {"error": "unauthorized"})
                return None
            guard.ok(ip)
            return principal

        def _manager(self):
            """The caller when it may manage devices, else None after sending 401/403."""
            principal = self._authenticate()
            if principal is None:
                return None
            if not principal.can_manage_devices:
                self._send_json(403, {"error": "forbidden", "message": "This token can't manage devices."})
                return None
            return principal

        def _device_list(self, principal):
            return {
                "host": short_hostname(),
                "companionVersion": VERSION,
                "devices": [devices.public(r, principal.device is not None and r["id"] == principal.device["id"])
                            for r in store.records()],
                "sharedToken": {"label": devices.SHARED_LABEL, "lastUsedAt": store.shared_last_used(),
                                "current": principal.kind == "shared"},
                "you": {"role": principal.role,
                        "deviceId": principal.device["id"] if principal.device else None},
            }

        def _audit(self, text):
            log(text)
            devices.append_audit(CONFIG_DIR, text)

        def do_GET(self):
            parts = urllib.parse.urlsplit(self.path)
            path = parts.path.rstrip("/") or "/"
            if path == "/health":
                return self._send_json(200, {"ok": True, "version": VERSION, "pollSeconds": poller.poll_seconds})
            if path in ("/v1/usage", "/v1/history"):
                principal = self._authenticate()
                if principal is None:
                    return
                query = urllib.parse.parse_qs(parts.query)
                # History never forces a provider fetch; it charts whatever is cached.
                force = path == "/v1/usage" and query.get("refresh", ["0"])[0] in ("1", "true", "yes")
                since = query.get("since", [None])[0] if path == "/v1/usage" and not force else None
                try:
                    if since is not None:
                        # Long-poll for `meterkat watch`: wait for the next snapshot without fetching.
                        try:
                            wait = min(MAX_WAIT_SECONDS, max(0.0, float(query.get("wait", ["60"])[0])))
                        except ValueError:
                            wait = 60.0
                        # Wait in short slices, so a device revoked meanwhile gets a 401 within seconds
                        # instead of the next snapshot.
                        deadline = time.monotonic() + wait
                        while True:
                            snap = poller.wait_newer(since, min(REVOKE_CHECK_SECONDS, max(0.0, deadline - time.monotonic())))
                            if principal.device and not store.exists(principal.device["id"]):
                                return self._send_json(401, {"error": "unauthorized"})
                            if snap.get("generatedAt") != since or time.monotonic() >= deadline:
                                break
                    else:
                        snap = poller.get(force=force)
                    # Filter here too, so a provider disabled since the last build disappears at once.
                    snap = without_providers(snap, disabled_providers())
                except Exception as e:
                    log("snapshot failed: %r" % e)
                    return self._send_json(500, {"error": "snapshot failed"})
                if path == "/v1/usage":
                    return self._send_json(200, dict(snap, companionId=cfg.get("companionId")))
                return self._send_json(200, history_payload(poller.history, snap,
                                                            query.get("provider", [None])[0],
                                                            query.get("window", [None])[0]))
            if path == "/v1/me":
                principal = self._authenticate()
                if principal is None:
                    return
                return self._send_json(200, {"role": principal.role, "kind": principal.kind,
                                             "deviceId": principal.device["id"] if principal.device else None,
                                             "name": principal.device["name"] if principal.device else None,
                                             "host": short_hostname(), "companionVersion": VERSION,
                                             **machine_info()})
            if path == "/v1/devices":
                principal = self._manager()
                if principal is None:
                    return
                return self._send_json(200, self._device_list(principal))
            if path == "/v1/pairing":
                # The link carries a pairing code, so only this machine (the Mac app, the CLI) gets it.
                if not is_local_request(self):
                    return self._send_json(403, {"error": "forbidden"})
                principal = self._authenticate()
                if principal is None:
                    return
                if principal.kind != "shared":
                    return self._send_json(403, {"error": "forbidden"})
                role = urllib.parse.parse_qs(parts.query).get("role", ["viewer"])[0]
                if role not in devices.ROLES:
                    return self._send_json(400, {"error": "bad_role"})
                # Re-read the URL overrides so `meterkat config set` applies without a restart.
                current = read_json_file(CONFIG_PATH)
                current = current if isinstance(current, dict) else {}
                merged = dict(cfg, localURL=current.get("localURL"), remoteURL=current.get("remoteURL"))
                try:
                    info = pairing_info(merged, port, bind_host, pairing_codes, role=role)
                except Exception as e:
                    log("pairing info failed: %r" % e)
                    return self._send_json(500, {"error": "pairing failed"})
                return self._send_json(200, info)
            return self._send_json(404, {"error": "not found"})

        def do_DELETE(self):
            path = urllib.parse.urlsplit(self.path).path.rstrip("/")
            if not path.startswith("/v1/devices/"):
                return self._send_json(404, {"error": "not found"})
            principal = self._manager()
            if principal is None:
                return
            ident = urllib.parse.unquote(path[len("/v1/devices/"):])
            try:
                # Only the machine itself may revoke the last owner.
                gone = store.revoke(ident, host=principal.kind == "shared" and principal.local)
            except devices.DeviceError as e:
                code = {"not_found": 404, "last_owner": 409}.get(e.code, 400)
                return self._send_json(code, {"error": e.code, "message": e.message})
            self._audit("revoked device %s \"%s\" (%s) by %s from %s"
                        % (gone["id"], gone["name"], gone["role"], principal.label, source_address(self)))
            self._send_json(200, {"revoked": devices.public(gone),
                                  "selfRevoked": bool(principal.device and principal.device["id"] == gone["id"])})

        def do_POST(self):
            path = urllib.parse.urlsplit(self.path).path.rstrip("/") or "/"
            if path not in ("/v1/pair", "/v1/devices/pairing-codes"):
                return self._send_json(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 0 or length > 4096:
                    raise ValueError("bad length")
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                body = json.loads(raw) if raw.strip() else {}
                if not isinstance(body, dict):
                    raise ValueError("not an object")
            except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                return self._send_json(400, {"error": "invalid request"})
            if path == "/v1/devices/pairing-codes":
                return self._issue_viewer_code(body)
            return self._redeem(body)

        def _issue_viewer_code(self, body):
            """An owner (or this machine's shared token) hands out a viewer pairing code."""
            principal = self._manager()
            if principal is None:
                return
            if body.get("role", "viewer") != "viewer":
                return self._send_json(403, {"error": "forbidden",
                                             "message": "Owner pairing codes come from `meterkat pair --owner` on the host."})
            current = read_json_file(CONFIG_PATH)
            current = current if isinstance(current, dict) else {}
            merged = dict(cfg, localURL=current.get("localURL"), remoteURL=current.get("remoteURL"))
            info = pairing_info(merged, port, bind_host, pairing_codes, role="viewer")
            info["expiresInSeconds"] = PAIRING_CODE_TTL
            self._audit("issued a viewer pairing code for %s from %s" % (principal.label, source_address(self)))
            self._send_json(200, info)

        def _redeem(self, body):
            ip = source_address(self)
            exempt = is_local_request(self)
            wait = 0 if exempt else guard.retry_after(ip)
            if wait:
                return self._send_json(429, {"error": "too_many_attempts"}, {"Retry-After": str(wait)})
            code = body.get("code")
            if not isinstance(code, str) or not code:
                return self._send_json(400, {"error": "invalid pairing code"})
            name = body.get("name")
            name = name.strip() if isinstance(name, str) else ""
            role = pairing_codes.peek_role(code)
            if role == "owner" and not name:
                # An owner token must belong to a named device, and old clients send no name.
                return self._send_json(400, {"error": "name_required",
                                             "message": "This owner pairing link needs a client that names itself."})
            redeemed = pairing_codes.redeem_with_role(code)
            if redeemed is None:
                if not exempt:
                    guard.fail(ip)
                return self._send_json(401, {"error": "pairing code expired or already used"})
            shared, role = redeemed
            if not name:
                # Older clients send no name and keep getting the shared token.
                return self._send_json(200, {"token": shared})
            try:
                token, record = store.mint(name, role)
            except devices.DeviceError as e:
                return self._send_json(409, {"error": e.code, "message": e.message})
            self._audit("paired device %s \"%s\" (%s) from %s" % (record["id"], record["name"], role, ip))
            return self._send_json(200, {"token": token, "deviceId": record["id"], "role": role,
                                         "name": record["name"]})

    return Handler


class DualStackServer(ThreadingHTTPServer):
    """IPv6 server (for --host ::) that also accepts IPv4 clients as ::ffff:a.b.c.d."""
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except (AttributeError, OSError):
            pass
        super().server_bind()


def serve(args, cfg):
    port = args.port or cfg["port"]
    poller = Poller(args.cache_seconds, History(history_path()))
    server_class = DualStackServer if ":" in args.host else ThreadingHTTPServer
    store = devices.DeviceStore(CONFIG_PATH)
    try:
        pairing_codes = PairingCodes()
        server = server_class((args.host, port), make_handler(poller, cfg, port, args.host, pairing_codes, store))
    except OSError as e:
        print("Cannot listen on %s:%d (%s)." % (args.host, port, e.strerror or e), file=sys.stderr)
        print("If the service is already running, check it with `meterkat status`.", file=sys.stderr)
        return 1
    server.daemon_threads = True
    announcer = start_announcing(cfg, port)
    poller.refresh_in_background()  # warm the cache before the first client asks
    poller.start_polling(args.poll_seconds)
    if sys.stdout.isatty():
        print_pairing(cfg, port, args.host, pairing_codes=pairing_codes)
    else:  # keep the token out of service logs
        log("Pair with `meterkat pair` or the Meterkat Mac app.")
    log("Listening on http://%s:%d (GET /v1/usage, GET /v1/history, GET /v1/pairing, GET /health)"
        % (args.host, port))
    def stop(*_):
        raise KeyboardInterrupt  # so the finally block below runs on `systemctl stop` too
    try:
        signal.signal(signal.SIGTERM, stop)
    except ValueError:  # not the main thread (tests)
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        store.flush()
        if announcer:
            announcer.stop()
        server.server_close()


def start_announcing(cfg, port):
    """Publishes `_meterkat._tcp` so Home Assistant can offer to set this companion up. Best effort."""
    if cfg.get("announce") is False:
        return None
    announcer = discovery.Announcer(short_hostname(), port, {
        "version": VERSION, "id": cfg.get("companionId"), "host": short_hostname(), "path": "/v1/usage"})
    if announcer.start():
        log("Announcing %s on the local network" % discovery.SERVICE_TYPE)
        return announcer
    return None


# --------------------------------------------------------------------------
# pair / once / status / config / restart
# --------------------------------------------------------------------------

def cmd_pair(args, cfg):
    port = args.port or cfg["port"]
    code, info = local_get(port, "/v1/pairing" + ("?role=owner" if getattr(args, "owner", False) else ""),
                           cfg["token"])
    if code != 200:
        print("meterkat: start or restart the companion before pairing.", file=sys.stderr)
        return 1
    print_pairing(cfg, port, args.host, info=info)
    png = getattr(args, "png", None)
    if not png:
        return 0
    png = os.path.expanduser(png)
    # It contains a pairing code: create it 0600 ourselves (no symlinks).
    try:
        fd = os.open(png, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        print("Cannot write %s: %s" % (png, e.strerror or e))
        return 1
    with os.fdopen(fd, "wb") as f:
        try:
            os.fchmod(fd, 0o600)  # an existing file keeps its old mode otherwise
        except OSError:
            pass
        f.write(qr.png(info["link"]))
    print("Wrote the pairing QR code to %s" % png)
    return 0


def device_rows(store, now=None):
    """Rows for `meterkat devices`: paired devices newest first, then the shared token."""
    rows = [devices.public(r) for r in store.records()]
    rows.append({"id": "shared", "name": devices.SHARED_LABEL, "role": "shared", "createdAt": None,
                 "lastUsedAt": store.shared_last_used(), "hint": None, "current": False})
    return rows


def format_when(iso, now=None):
    if not iso:
        return "never"
    return "%s (%s)" % (devices.local_stamp(iso), devices.relative(iso, now))


def cmd_devices(args, cfg):
    store = devices.DeviceStore(CONFIG_PATH)
    action = getattr(args, "devices_action", None) or "list"
    if action == "revoke":
        return revoke_device(store, args)
    rows = device_rows(store)
    if getattr(args, "json", False):
        print(json.dumps({"host": short_hostname(), "devices": rows[:-1], "sharedToken": rows[-1]}, indent=2))
        return 0
    paired = rows[:-1]
    if not paired:
        print("No paired devices yet. Pair one with `meterkat pair`.")
    header = ("NAME", "ROLE", "AUTHORIZED", "LAST ACTIVE", "ID")
    table = [header] + [
        (r["name"], r["role"], format_when(r["createdAt"]) if r["createdAt"] else "-",
         format_when(r["lastUsedAt"]), r["id"] + ("  …" + r["hint"] if r["hint"] else ""))
        for r in rows]
    widths = [max(len(row[i]) for row in table) for i in range(len(header))]
    print("")
    for i, row in enumerate(table):
        line = "  ".join(cell.ljust(widths[n]) for n, cell in enumerate(row)).rstrip()
        print(paint(line, BOLD) if i == 0 else line)
    print("")
    print("The shared token is what the iPhone and Mac apps use until they pair again with their own. It can't")
    print("be revoked on its own: `meterkat config rotate-token` replaces it, and every client that still")
    print("holds it must pair again.")
    print("Revoke a device: meterkat devices revoke <id or name>")
    return 0


def revoke_device(store, args):
    records = [r for r in store.records()]
    try:
        target = devices.resolve(records, args.device, by_name=True)
    except devices.DeviceError as e:
        print("meterkat: %s" % e.message, file=sys.stderr)
        return 1
    print("Revoke %s \"%s\" (%s, last active %s)?" % (target["id"], target["name"], target["role"],
                                                      format_when(target.get("lastUsedAt"))))
    if not args.yes:
        if not sys.stdin.isatty():
            print("meterkat: not a terminal; pass --yes to revoke.", file=sys.stderr)
            return 1
        if not ask_yes_no("It stops working immediately. Revoke it?", False):
            print("Not revoked.")
            return 1
    try:
        gone = store.revoke(target["id"], host=True)
    except devices.DeviceError as e:
        print("meterkat: %s" % e.message, file=sys.stderr)
        return 1
    devices.append_audit(CONFIG_DIR, "revoked device %s \"%s\" (%s) by the host CLI (user %s)"
                         % (gone["id"], gone["name"], gone["role"], getpass.getuser()))
    print("Revoked %s \"%s\". The running service rejects its token from now on." % (gone["id"], gone["name"]))
    return 0


def print_current_pairing(cfg, port, bind_host="0.0.0.0", every_address=True):
    code, info = local_get(port, "/v1/pairing", cfg["token"])
    if code != 200:
        print("meterkat: start or restart the companion before pairing.", file=sys.stderr)
        return False
    print_pairing(cfg, port, bind_host, every_address=every_address, info=info)
    return True


def cmd_once(args, cfg):
    print(json.dumps(Poller(0).build(), indent=2))
    return 0


def cmd_usage(args, cfg):
    """Print the running companion's snapshot for local tools and AI agents."""
    port = args.port or cfg["port"]
    path = "/v1/usage?refresh=1" if args.refresh else "/v1/usage"
    code, snapshot = local_get(port, path, cfg["token"], timeout=HTTP_TIMEOUT + 5)
    if code == 401:
        print("meterkat: the running companion rejected the token; run `meterkat restart`.", file=sys.stderr)
        return 1
    if code != 200 or not isinstance(snapshot, dict):
        print("meterkat: usage unavailable on 127.0.0.1:%d; run `meterkat status`." % port,
              file=sys.stderr)
        return 1
    if args.provider:
        snapshot = dict(snapshot, providers=[p for p in snapshot.get("providers", [])
                                             if p["id"] == args.provider])
    print(json.dumps(snapshot, indent=2))
    return 0


def cmd_history(args, cfg):
    """Print usage history and the companion's per-window rate projections."""
    port = args.port or cfg["port"]
    query = []
    if args.provider:
        query.append(("provider", args.provider))
    if args.window:
        query.append(("window", args.window))
    path = "/v1/history"
    if query:
        path += "?" + urllib.parse.urlencode(query)
    code, history = local_get(port, path, cfg["token"], timeout=HTTP_TIMEOUT + 5)
    if code == 401:
        print("meterkat: the running companion rejected the token; run `meterkat restart`.", file=sys.stderr)
        return 1
    if code != 200 or not isinstance(history, dict):
        print("meterkat: usage history unavailable on 127.0.0.1:%d; run `meterkat status`." % port,
              file=sys.stderr)
        return 1
    print(json.dumps(history, indent=2))
    return 0


# --------------------------------------------------------------------------
# watch
# --------------------------------------------------------------------------

WATCH_DEFAULTS = {"session": 85.0}  # every other kind: WATCH_DEFAULT_OTHER
WATCH_DEFAULT_OTHER = 95.0
WATCH_LIMIT_EXIT = 3
WATCH_NO_READING_EXIT = 4
WATCH_WAIT_SECONDS = 300
WATCH_FALLBACK_SLEEP = 30  # an old companion without long-poll answers at once


def parse_thresholds(specs):
    """`--at 85` sets every kind; `--at session=80 --at model=off` sets one.
    Returns {kind: percent or None (off)}, with "*" for every other kind."""
    out = dict(WATCH_DEFAULTS, **{"*": WATCH_DEFAULT_OTHER})
    for spec in specs or []:
        kind, sep, value = spec.rpartition("=")
        kind = kind.strip().lower() if sep else "*"
        if kind != "*" and kind not in WINDOW_KINDS:
            raise ValueError("unknown window kind %r (use one of: %s)" % (kind, ", ".join(WINDOW_KINDS)))
        value = value.strip().lower()
        if value in ("off", "none"):
            pct = None
        else:
            try:
                pct = float(value.rstrip("%"))
            except ValueError:
                raise ValueError("bad threshold %r: give a percent such as 85, or off" % spec)
            if not 0 < pct <= 100:
                raise ValueError("bad threshold %r: give a percent from 1 to 100" % spec)
        if kind == "*":
            out = {k: pct for k in out}
        else:
            out[kind] = pct
    return out


def threshold_for(thresholds, kind):
    return thresholds.get(kind, thresholds.get("*"))


def local_time(iso):
    try:
        t = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return "no reset time"
    return t.astimezone().strftime("%Y-%m-%d %H:%M %Z")


def watch_check(snapshot, provider_id, thresholds, now=None):
    """One reading -> (state key, events). An event is a dict with `event`
    OK | WARN | LIMIT and a human `message`. The key changes only when a
    line is worth printing: a 10-point step, staleness, or a status change."""
    now = now if now is not None else time.time()
    p = next((x for x in snapshot.get("providers") or [] if x.get("id") == provider_id), None)
    base = {"provider": provider_id, "generatedAt": snapshot.get("generatedAt")}
    if p is None:
        msg = "WARN %s not tracked by Meterkat (disabled or unknown)" % provider_id
        return "absent", [dict(base, event="WARN", message=msg)]
    status = p.get("status")
    if status != "ok":
        msg = "WARN %s status %s: %s" % (provider_id, status, p.get("error") or "")
        return "status-%s" % status, [dict(base, event="WARN", status=status, error=p.get("error"), message=msg)]
    stale = bool(p.get("stale"))
    parts, key, hits = [], [], []
    for w in p.get("windows") or []:
        pct = to_float(w.get("percent")) or 0.0
        kind, label, resets = w.get("kind"), w.get("label") or w.get("id"), w.get("resetsAt")
        reset_epoch = epoch_seconds(resets)
        expired = reset_epoch is not None and reset_epoch <= now
        parts.append("%s %.0f%%%s" % (label, pct, " (expired)" if expired else ""))
        key.append("%s:%d" % (w.get("id"), int(pct // 10)))
        limit = threshold_for(thresholds, kind)
        if limit is not None and pct >= limit and not expired:
            hits.append(dict(base, event="LIMIT", kind=kind, windowId=w.get("id"), label=label,
                             percent=pct, threshold=limit, resetsAt=resets, stale=stale,
                             message="LIMIT %s %s (%s) %.0f%% >= %.0f%%, resets %s (resetsAt %s)"
                                     % (provider_id, kind, label, pct, limit, local_time(resets), resets)))
    if hits:
        return "limit", hits
    suffix = " STALE" if stale else ""
    if stale and p.get("error"):
        suffix += " (%s)" % p["error"]
    msg = "OK %s%s: %s" % (provider_id, suffix, ", ".join(parts) or "no limits reported")
    readings = [{"kind": w.get("kind"), "windowId": w.get("id"), "label": w.get("label"),
                 "percent": to_float(w.get("percent")) or 0.0, "resetsAt": w.get("resetsAt")}
                for w in p.get("windows") or []]
    return "|".join(key) + (" stale" if stale else ""), [dict(base, event="OK", stale=stale, windows=readings,
                                                              message=msg)]


def watch_no_reading(snapshot, provider_id):
    """True when the snapshot can't show this provider is below its limits:
    absent, status not ok, stale, no windows, or every window already reset."""
    p = next((x for x in snapshot.get("providers") or [] if x.get("id") == provider_id), None)
    if p is None or p.get("status") != "ok" or p.get("stale"):
        return True
    now = time.time()
    resets = [epoch_seconds(w.get("resetsAt")) for w in p.get("windows") or []]
    return all(r is not None and r <= now for r in resets)


def cmd_watch(args, cfg):
    """Print when a provider's usage crosses a threshold, riding on the service's own polling."""
    try:
        thresholds = parse_thresholds(args.at)
    except ValueError as e:
        print("meterkat watch: %s" % e, file=sys.stderr)
        return 2
    port = args.port or cfg["port"]
    state, since, warned_poll = None, None, False

    def emit(events):
        for ev in events:
            line = json.dumps({k: v for k, v in ev.items() if k != "message"}) if args.json else ev["message"]
            print(line, flush=True)

    while True:
        path = "/v1/usage"
        if since is not None:
            path += "?since=%s&wait=%d" % (urllib.parse.quote(since), WATCH_WAIT_SECONDS)
        started = time.monotonic()
        code, snapshot = local_get(port, path, cfg["token"], timeout=WATCH_WAIT_SECONDS + HTTP_TIMEOUT + 5)
        if code != 200 or not isinstance(snapshot, dict):
            why = ("the running companion rejected the token; run `meterkat restart`" if code == 401
                   else "usage unavailable on 127.0.0.1:%d; run `meterkat status`" % port)
            if state != "error":
                emit([{"event": "ERROR", "provider": args.provider, "message": "ERROR %s" % why}])
            state, since = "error", None
            if args.once:
                return 1
            time.sleep(WATCH_FALLBACK_SLEEP)
            continue
        if not warned_poll:
            warned_poll = True
            _, health = local_get(port, "/health")
            if isinstance(health, dict) and health.get("pollSeconds") == 0:
                emit([{"event": "WARN", "provider": args.provider,
                       "message": "WARN the service runs with --poll-seconds 0; "
                                  "readings update only when a client asks"}])
        key, events = watch_check(snapshot, args.provider, thresholds)
        no_reading = args.once and key != "limit" and watch_no_reading(snapshot, args.provider)
        if no_reading:  # exit 4 must not come with an OK line
            events = [dict(ev, event="WARN", message="WARN no usable reading: %s" % ev["message"][len("OK "):])
                      if ev["event"] == "OK" else ev for ev in events]
        if key != state:
            emit(events)
        state = key
        if key == "limit":
            return WATCH_LIMIT_EXIT
        if args.once:
            return WATCH_NO_READING_EXIT if no_reading else 0
        generated = snapshot.get("generatedAt")
        if since is not None and generated == since and time.monotonic() - started < 1:
            time.sleep(WATCH_FALLBACK_SLEEP)  # a companion without long-poll support
        since = generated


def service_state():
    """Return (installed, running, detail) for the background service."""
    if IS_MAC:
        out = run_cmd(["launchctl", "print", "gui/%d/%s" % (os.getuid(), LAUNCHD_LABEL)])
        if out is None:
            return os.path.exists(LAUNCHD_PLIST), False, "launchd %s: not loaded" % LAUNCHD_LABEL
        state = re.search(r"^\s*state = (.+)$", out, re.M)
        pid = re.search(r"^\s*pid = (\d+)", out, re.M)
        state = state.group(1).strip() if state else "loaded"
        detail = "launchd %s: %s" % (LAUNCHD_LABEL, state) + (", pid %s" % pid.group(1) if pid else "")
        return True, state == "running", detail
    if sys.platform.startswith("linux"):
        try:
            res = subprocess.run(["systemctl", "--user", "is-active", SYSTEMD_UNIT_NAME],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
            state = res.stdout.decode("utf-8", "replace").strip() or "unknown"
        except Exception:
            state = "systemctl unavailable"
        return os.path.exists(SYSTEMD_UNIT), state == "active", "systemd --user %s: %s" % (SYSTEMD_UNIT_NAME, state)
    return False, False, "unsupported platform"


def local_get(port, path, token=None, timeout=3):
    """GET http://127.0.0.1:<port><path>, bypassing proxies. Returns (status or None, json or None)."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path))
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return None, None


def _time_left(iso):
    try:
        reset = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None
    mins = int((reset - datetime.now(timezone.utc)).total_seconds() // 60)
    if mins <= 0:
        return None
    if mins >= 1440:
        return "%dd %dh" % (mins // 1440, mins % 1440 // 60)
    return "%dh %dm" % (mins // 60, mins % 60) if mins >= 60 else "%dm" % mins


def usage_summary(provider):
    head = str(provider.get("name") or provider.get("id"))
    if provider.get("plan"):
        head += " (%s)" % provider["plan"]
    if provider.get("status") != "ok":
        return "%s: %s" % (head, provider.get("error") or provider.get("status"))
    if provider.get("stale"):
        fetched = epoch_seconds(provider.get("fetchedAt"))
        if fetched is not None:
            head += " [stale, from %s]" % relative_age(time.time() - fetched)
    parts = []
    for w in provider.get("windows") or []:
        part = "%s %.0f%%" % (w.get("label"), to_float(w.get("percent")) or 0)
        left = _time_left(w.get("resetsAt"))
        if left:
            part += " (resets in %s)" % left
        parts.append(part)
    return "%s: %s" % (head, ", ".join(parts) or "no limits reported")


def cmd_status(args, cfg):
    port = args.port or cfg["port"]
    installed, running, detail = service_state()
    print("meterkat %s (%s)" % (VERSION, os.path.realpath(__file__)))
    state = "running" if running else ("installed, not running" if installed else "not installed")
    print("Service:  %s (%s)" % (state, detail))
    if IS_MAC:
        app = find_mac_app()
        login = "opens at login" if os.path.exists(MENUBAR_PLIST) else "not a login item"
        print("Mac app:  %s" % ("%s, %s" % (app, login) if app else "not installed"))
    code, health = local_get(port, "/health")
    if code != 200:
        print("Health:   nothing answering on 127.0.0.1:%d" % port)
        return 1
    print("Health:   ok on 127.0.0.1:%d (companion %s)" % (port, (health or {}).get("version", "1.0")))
    code, snap = local_get(port, "/v1/usage", cfg["token"], timeout=HTTP_TIMEOUT + 5)
    if code == 401:
        print("Usage:    401, the running companion has a different token; run `meterkat restart`.")
        return 1
    if code != 200 or not isinstance(snap, dict):
        print("Usage:    request failed (%s)" % (code or "no response"))
        return 1
    for p in snap.get("providers") or []:
        print("  " + usage_summary(p))
    disabled = disabled_providers(cfg)
    for pid, name, _ in PROVIDERS:
        if pid in disabled:
            print("  %s: disabled (meterkat config enable %s)" % (name, pid))
    return 0


def restart_service():
    """Restart the installed service so it picks up a new token. False if not installed."""
    try:
        if IS_MAC and os.path.exists(LAUNCHD_PLIST):
            cmd = ["launchctl", "kickstart", "-k", "gui/%d/%s" % (os.getuid(), LAUNCHD_LABEL)]
        elif sys.platform.startswith("linux") and os.path.exists(SYSTEMD_UNIT):
            cmd = ["systemctl", "--user", "restart", SYSTEMD_UNIT_NAME]
        else:
            return False
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def cmd_restart(args, cfg):
    if restart_service():
        print("Restarted the background service.")
        return 0
    print("The background service isn't installed or failed to restart; see `meterkat status`.")
    return 1


def installed_files_match(src):
    """True when the companion modules in the checkout `src` are the ones installed here."""
    here = os.path.dirname(os.path.realpath(__file__))
    names = [n for n in os.listdir(src) if n.endswith(".py") and not n.startswith("test_")]
    for name in names:
        try:
            with open(os.path.join(src, name), "rb") as a, open(os.path.join(here, name), "rb") as b:
                if a.read() != b.read():
                    return False
        except OSError:
            return False
    return bool(names)


def source_version(path):
    try:
        with open(path) as f:
            match = re.search(r'^VERSION = "([^"]+)"', f.read(), re.M)
    except OSError:
        return None
    return match.group(1) if match else None


def cmd_update(args, cfg):
    """Pull the checkout install.sh was run from, copy it in again, and restart the service."""
    src = args.source
    if not src:
        try:
            with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "source")) as f:
                src = f.read().strip()
        except OSError:
            pass
    if not src:
        print("This install doesn't record where it came from (installed before 1.9.0).")
        print("Run ./companion/install.sh once from your checkout, or `meterkat update --from PATH`.")
        return 1
    src = os.path.abspath(os.path.expanduser(src))
    if os.path.isfile(os.path.join(src, "companion", "install.sh")):
        src = os.path.join(src, "companion")  # --from the repo root
    installer = os.path.join(src, "install.sh")
    if not os.path.isfile(installer):
        print("No install.sh in %s. Point `meterkat update --from` at the repo's companion folder." % src)
        return 1
    git = shutil.which("git")
    inside = run_cmd([git, "-C", src, "rev-parse", "--is-inside-work-tree"]) if git else None
    in_checkout = (inside or "").strip() == "true"
    if in_checkout and not args.no_pull:
        print("Pulling %s" % src, flush=True)
        if subprocess.run([git, "-C", src, "pull", "--ff-only"]).returncode != 0:
            print("git pull failed. Fix the checkout, or run `meterkat update --no-pull` to install it as is.")
            return 1
    new_version = source_version(os.path.join(src, "meterkat.py")) or "?"
    if installed_files_match(src) and not args.force:
        print("Already up to date (meterkat %s)." % VERSION)
        return 0
    # The new install.sh knows which files the new version needs.
    if subprocess.run(["/bin/sh", installer, "--files-only"]).returncode != 0:
        print("install.sh failed; the previous version may be partly replaced. Run it again by hand:")
        print("  %s" % installer)
        return 1
    if new_version == VERSION:
        print("Reinstalled meterkat %s from %s" % (VERSION, src))
    else:
        print("Updated meterkat %s -> %s" % (VERSION, new_version))
    if not os.path.exists(LAUNCHD_PLIST if IS_MAC else SYSTEMD_UNIT):
        print("The background service isn't installed; run `meterkat install` to start it.")
        return 0
    if not restart_service():
        print("The service failed to restart; see `meterkat status`.")
        return 1
    print("Restarted the background service.")
    return 0


def cmd_config(args, cfg):
    action = getattr(args, "config_action", None) or "show"
    if action in ("enable", "disable"):
        disabled = disabled_providers(cfg)
        if action == "disable":
            disabled.add(args.provider)
        else:
            disabled.discard(args.provider)
        if disabled:
            cfg["disabledProviders"] = [pid for pid in PROVIDER_IDS if pid in disabled]
        else:
            cfg.pop("disabledProviders", None)
        save_config(cfg)
        name = next(n for pid, n, _ in PROVIDERS if pid == args.provider)
        print("%s %sd." % (name, action))
        print("The running service picks this up within a couple of minutes (or run `meterkat restart`).")
        return 0
    if action == "set":
        url = normalize_base_url(args.url)
        try:
            parts = urllib.parse.urlsplit(url or "")
            parts.port  # raises ValueError on a bad port
        except ValueError:
            parts = None
        if not parts or not parts.hostname or parts.scheme not in ("http", "https"):
            print("Not a valid http(s) URL: %s" % args.url)
            return 1
        if parts.scheme == "http" and parts.port is None:
            # A bare host means this companion, not port 80 (write :80 explicitly for a proxy).
            url = urllib.parse.urlunsplit(parts._replace(netloc="%s:%d" % (parts.netloc, cfg["port"])))
        cfg[URL_KEYS[args.key]] = url
        save_config(cfg)
        print("%s set to %s" % (args.key, url))
        print("Re-pair the iPhone to use it: meterkat pair")
        return 0
    if action == "unset":
        cfg.pop(URL_KEYS[args.key], None)
        save_config(cfg)
        print("%s is auto-detected again. Re-pair the iPhone to use it: meterkat pair" % args.key)
        return 0
    if action == "set-key":
        name = next(n for pid, n, _ in PROVIDERS if pid == args.provider)
        # A prompt keeps the key out of the shell history; piped input works too.
        if sys.stdin.isatty():
            key = getpass.getpass("%s %s: " % (name, "token" if args.provider == "copilot" else "API key"))
        else:
            key = sys.stdin.readline()
        key = key.strip()
        if not key:
            print("No key given; nothing saved.")
            return 1
        cfg[API_KEY_KEYS[args.provider]] = key
        save_config(cfg)
        print("Saved the %s key %s to %s (mode 600)." % (name, mask_token(key), CONFIG_PATH))
        print("The running service picks it up within a couple of minutes (or run `meterkat restart`).")
        return 0
    if action == "unset-key":
        name = next(n for pid, n, _ in PROVIDERS if pid == args.provider)
        cfg.pop(API_KEY_KEYS[args.provider], None)
        save_config(cfg)
        print("Deleted the saved %s key." % name)
        return 0
    if action == "announce":
        if args.state == "off":
            cfg["announce"] = False
        else:
            cfg.pop("announce", None)
        save_config(cfg)
        print("Local-network announcement %s." % ("turned off" if args.state == "off" else "turned on"))
        print("It applies after `meterkat restart`.")
        return 0
    if action == "rotate-token":
        cfg["token"] = secrets.token_urlsafe(24)
        save_config(cfg)
        print("New token %s saved to %s" % (mask_token(cfg["token"]), CONFIG_PATH))
        if restart_service():
            print("Restarted the background service with the new token.")
        print("Re-pair the iPhone: meterkat pair (or open the Meterkat Mac app).")
        return 0
    info = pairing_info(cfg, args.port or cfg["port"], args.host)
    print("Config:     %s" % CONFIG_PATH)
    print("token:      %s" % mask_token(cfg["token"]))
    print("port:       %s" % cfg["port"])
    for name, key, kind in (("local-url", "localURL", "local"), ("remote-url", "remoteURL", "remote")):
        source = "set" if normalize_base_url(cfg.get(key)) else "auto-detected"
        print("%-11s %s (%s)" % (name + ":", info[kind] or "none", source))
    for pid, key in sorted(API_KEY_KEYS.items()):
        saved = cfg.get(key)
        print("%-11s %s" % (pid + ":", "key %s saved" % mask_token(saved) if saved else "no saved key"))
    disabled = disabled_providers(cfg)
    print("providers:  %s" % ", ".join("%s (%s)" % (pid, "disabled" if pid in disabled else "enabled")
                                       for pid in PROVIDER_IDS))
    return 0


# --------------------------------------------------------------------------
# setup: the terminal version of the Mac app's first-run setup
# --------------------------------------------------------------------------

def ensure_user_bus_env():
    """`systemctl --user` finds the user's systemd through $XDG_RUNTIME_DIR, which shells outside a
    login session (su, some IDE terminals) don't set. The directory is /run/user/<uid> whenever the
    user's systemd runs, so point at it. Returns False when it isn't running."""
    if os.environ.get("XDG_RUNTIME_DIR"):
        return True
    runtime = "/run/user/%d" % os.getuid()
    if not os.path.isdir(runtime):
        return False
    os.environ["XDG_RUNTIME_DIR"] = runtime
    bus = os.path.join(runtime, "bus")
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS") and os.path.exists(bus):
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + bus
    return True


def linger_enabled():
    """True when systemd keeps this user's services running without a login session."""
    user = os.environ.get("USER") or getpass.getuser()
    out = run_cmd(["loginctl", "show-user", user, "--property=Linger"], timeout=5)
    return bool(out) and out.strip() == "Linger=yes"


def ask_yes_no(question, default):
    """Enter (or the end of piped input) takes the default."""
    hint = "[Y/n]" if default else "[y/N]"
    while True:
        try:
            answer = input("%s %s " % (question, paint(hint, DIM))).strip().lower()
        except EOFError:
            print()
            return default
        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print("Answer y or n.")


def ask_secret(prompt):
    """Hidden on a terminal; read from stdin when piped. Empty means skip."""
    try:
        if sys.stdin.isatty():
            return getpass.getpass(prompt).strip()
        print(prompt, end="", flush=True)
        line = sys.stdin.readline()
        print()
        return line.strip()
    except EOFError:
        return ""


def wait_for_enter(prompt):
    try:
        input(paint(prompt, DIM))
    except EOFError:
        print()


SETUP_STEPS = ("Providers", "Service", "Pair")


def setup_screen(step, clear):
    """Starts a setup step: a fresh screen on a terminal, a header and where we are in the steps."""
    if clear:
        sys.stdout.write("\033[H\033[2J\033[3J")
    width = min(shutil.get_terminal_size().columns, 100)
    print(paint(" Meterkat ", BOLD, 30, 46) + "  companion setup " + paint("%s on %s" % (VERSION, short_hostname()), DIM))
    trail = []
    for i, name in enumerate(SETUP_STEPS, 1):
        if i < step:
            trail.append(paint("✓ " + name, GREEN))
        elif i == step:
            trail.append(paint("%d %s" % (i, name), BOLD, CYAN))
        else:
            trail.append(paint("%d %s" % (i, name), DIM))
    print(paint(" ─ ", DIM).join(trail))
    print(paint("─" * width, DIM))
    print()


def print_detected(providers):
    width = shutil.get_terminal_size().columns
    print(paint("Found on this machine", BOLD))
    for p in providers:
        if p["found"]:
            print("  %s %-15s %s" % (paint("✓", GREEN), p["name"], paint(fit(p["source"], width - 20), DIM)))
        else:
            print("  %s %s %s" % (paint("·", DIM), paint("%-15s" % p["name"], DIM), paint(fit(p["hint"], width - 20), DIM)))
    print()


def pick_providers(providers, chosen):
    """A checklist: arrow keys or j/k move, Space toggles, a toggles all, Enter confirms. Returns the
    chosen ids, or None when the terminal can't do it."""
    try:
        import termios
        import tty
        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)
    except Exception:  # no termios, or stdin isn't a terminal
        return None
    chosen = set(chosen)
    cursor = 0
    width = shutil.get_terminal_size().columns

    def draw(first):
        if not first:
            sys.stdout.write("\033[%dA" % len(providers))
        for i, p in enumerate(providers):
            here = i == cursor
            box = paint("[✓]", GREEN) if p["id"] in chosen else "[ ]"
            pointer = paint("›", BOLD, CYAN) if here else " "
            name = "%-15s" % p["name"]
            detail = fit(p["source"] if p["found"] else ("not found: " + p["hint"]), width - 26)
            sys.stdout.write("\r\033[K %s %s %s %s\n" % (pointer, box, paint(name, BOLD) if here else name,
                                                        paint(detail, DIM)))
        sys.stdout.flush()

    print(paint("↑/↓ move   Space turn on/off   a all   Enter done", DIM))
    sys.stdout.write("\033[?25l")  # hide the cursor
    try:
        tty.setcbreak(fd)
        draw(True)
        while True:
            key = os.read(fd, 8)
            if key in (b"\r", b"\n"):
                return chosen
            if key in (b"\x1b[A", b"\x1bOA", b"k"):
                cursor = (cursor - 1) % len(providers)
            elif key in (b"\x1b[B", b"\x1bOB", b"j"):
                cursor = (cursor + 1) % len(providers)
            elif key == b" ":
                chosen ^= {providers[cursor]["id"]}
            elif key == b"a":
                every = {p["id"] for p in providers}
                chosen = set() if chosen == every else every
            elif key in (b"\x03", b"\x04"):
                raise KeyboardInterrupt
            draw(False)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()


def ask_providers(providers, suggested, interactive):
    """The providers to track, from the checklist on a terminal and one question each otherwise."""
    print("Choose the providers to track. The ones you turn off aren't checked and don't show up")
    print("in the apps.")
    if interactive:
        chosen = pick_providers(providers, suggested)
        if chosen is not None:
            return chosen
    print("Press Enter for the suggested answer.")
    return {p["id"] for p in providers if ask_yes_no("Track %s?" % p["name"], p["id"] in suggested)}


def cmd_setup(args, cfg):
    """Choose providers (and keys), then install the service and show the pairing code."""
    interactive = not args.yes and sys.stdin.isatty() and sys.stdout.isatty()
    try:
        return _setup(args, cfg, interactive)
    except KeyboardInterrupt:
        sys.stdout.write("\033[?25h\n")
        print("Setup stopped. Run `meterkat setup` to start again.")
        return 130


def _setup(args, cfg, interactive):
    setup_screen(1, interactive)
    print("The companion reads the AI tools you're signed in to on this machine and serves your usage")
    print("to the Meterkat apps. Provider tokens never leave this machine.")
    print()
    providers = detect_providers(cfg)
    print_detected(providers)

    found = [p for p in providers if p["found"]]
    # Until something is turned off, suggest what was found; afterwards keep the current choice.
    first_run = all(p["enabled"] for p in providers)
    suggested = {p["id"] for p in providers if (p["found"] if first_run else p["enabled"])}
    took_detected = False
    if args.yes:
        chosen = suggested
    elif found and ask_yes_no("Turn on all %d detected provider%s (%s)?" % (
            len(found), "" if len(found) == 1 else "s", ", ".join(p["name"] for p in found)), True):
        chosen = {p["id"] for p in found}
        took_detected = True
    else:
        print()
        chosen = ask_providers(providers, suggested, interactive)

    if not args.yes:
        keyless = [p for p in providers if p["takesKey"] and not p["found"]]
        if took_detected:
            wanted = []
            if keyless and ask_yes_no("Add a key for %s too?" % " or ".join(p["name"] for p in keyless), False):
                wanted = keyless
        else:
            wanted = [p for p in keyless if p["id"] in chosen]
        for p in wanted:
            kind = "token" if p["id"] == "copilot" else "API key"
            key = ask_secret("  %s %s (Enter to skip): " % (p["name"], kind))
            if key:
                cfg[API_KEY_KEYS[p["id"]]] = key
                chosen.add(p["id"])
                print("  Saved %s." % mask_token(key))

    disabled = [pid for pid in PROVIDER_IDS if pid not in chosen]
    if disabled:
        cfg["disabledProviders"] = disabled
    else:
        cfg.pop("disabledProviders", None)
    save_config(cfg)
    tracked = [p["name"] for p in providers if p["id"] in chosen]

    if interactive:
        setup_screen(2, True)
    else:
        print()
    print("%s %s" % (paint("Tracking:", BOLD), ", ".join(tracked) or "nothing yet"))
    print()
    print("The background service serves your usage to the apps. It starts at login and restarts if")
    print("it stops.")
    if not (args.yes or ask_yes_no("Install the background service now?", True)):
        print("Not installed. Run `meterkat install` when you're ready, then `meterkat pair`.")
        return 0
    print()
    code = install(args, cfg, show_pairing=False)
    if code != 0:
        return code
    print()
    print(paint("✓ The service is running.", GREEN))
    if interactive:
        print()
        wait_for_enter("Press Enter to pair your iPhone...")
        setup_screen(3, True)
    # The QR code has to fit on the screen; `meterkat pair` lists every address.
    print_current_pairing(cfg, cfg["port"], args.host, every_address=False)
    print(paint("You're set.", BOLD) + " `meterkat status` checks the service, `meterkat pair` shows this code")
    print("again, and `meterkat setup` changes the providers.")
    return 0


# --------------------------------------------------------------------------
# install / uninstall
# --------------------------------------------------------------------------

def _service_args(args):
    # No --port: the service reads it from config.json like the Mac app, pair and status.
    # install.sh passes the python3 it found on PATH (/usr/bin/python3, /opt/homebrew/bin/python3).
    # sys.executable is where that resolves to, inside Xcode or a versioned Homebrew keg, which an
    # update can remove.
    python = os.environ.get("METERKAT_PYTHON") or sys.executable
    cmd = [python, os.path.realpath(__file__), "serve"]
    if args.host != "0.0.0.0":
        cmd += ["--host", args.host]
    if args.cache_seconds != DEFAULT_CACHE_SECONDS:
        cmd += ["--cache-seconds", str(args.cache_seconds)]
    if args.poll_seconds != DEFAULT_POLL_SECONDS:
        cmd += ["--poll-seconds", str(args.poll_seconds)]
    return cmd


def _service_env():
    env = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
           "PYTHONUNBUFFERED": "1"}
    # No API keys or tokens (OPENCODE_API_KEY, OPENROUTER_API_KEY, ZAI_API_KEY, GH_TOKEN...): the
    # plist/unit would hold the secret. The service reads the tools' own credential files, `gh auth
    # token`, and the keys saved by `meterkat config set-key` (config.json, mode 600).
    for key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME",
                "GH_CONFIG_DIR"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    return env


def _launchd_load(label, plist_path, plist):
    """Write a LaunchAgent plist and (re)load it. Returns launchctl's exit code."""
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f)
    domain = "gui/%d" % os.getuid()
    target = domain + "/" + label
    subprocess.run(["launchctl", "bootout", target],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # bootout returns before the old job is gone; bootstrapping too early
    # fails with "5: Input/output error".
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and subprocess.run(
            ["launchctl", "print", target],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        time.sleep(0.2)
    code = subprocess.run(["launchctl", "bootstrap", domain, plist_path],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    if code != 0:  # still finishing; retry once and let the error show
        time.sleep(1)
        code = subprocess.run(["launchctl", "bootstrap", domain, plist_path]).returncode
    return code


def find_mac_app():
    return next((path for path in MAC_APP_PATHS if os.path.isdir(path)), None)


def quit_app(app):
    pattern = app + "/Contents/MacOS/"
    subprocess.run(["pkill", "-f", pattern], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):
        if run_cmd(["pgrep", "-f", pattern]) is None:
            return
        time.sleep(0.1)


def install_menubar():
    """Open the Meterkat Mac app at login, replacing the old swiftc-built menu bar app. Failures only warn."""
    app = find_mac_app()
    if not app:
        print("")
        print("The Meterkat Mac app isn't installed, so the menu bar part is skipped.")
        print("Download it, or build it from the repo with Mac/build.sh --install (needs Xcode),")
        print("then run `meterkat install` again.")
        return False
    if os.path.isdir(LEGACY_MENUBAR_APP):
        quit_app(LEGACY_MENUBAR_APP)
        shutil.rmtree(LEGACY_MENUBAR_APP, ignore_errors=True)
        print("Removed the old menu bar app %s" % LEGACY_MENUBAR_APP)
    plist = {
        "Label": MENUBAR_LABEL,
        # --background: start in the menu bar and Dock without opening the window.
        "ProgramArguments": ["/usr/bin/open", "-a", app, "--args", "--background"],
        "RunAtLoad": True,
    }
    if _launchd_load(MENUBAR_LABEL, MENUBAR_PLIST, plist) != 0:
        print("Warning: could not register %s; open %s yourself instead." % (MENUBAR_LABEL, app))
    subprocess.run(["/usr/bin/open", "-a", app])
    print("%s opens at login" % app)
    return True


def remove_old_install():
    """Stop and delete the pre-2.0 `aiusage` service, CLI, and Mac app. Config is left in place."""
    home = os.path.expanduser("~")
    if IS_MAC:
        domain = "gui/%d" % os.getuid()
        for label in OLD_LAUNCHD_LABELS:
            path = os.path.join(home, "Library", "LaunchAgents", label + ".plist")
            if os.path.exists(path):
                subprocess.run(["launchctl", "bootout", domain + "/" + label],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                os.remove(path)
                print("Removed the old LaunchAgent %s" % label)
        for app in OLD_MAC_APPS:
            if os.path.isdir(app):
                quit_app(app)
                shutil.rmtree(app, ignore_errors=True)
                print("Deleted the old app %s" % app)
    elif sys.platform.startswith("linux"):
        unit = os.path.join(os.path.dirname(SYSTEMD_UNIT), OLD_SYSTEMD_UNIT_NAME)
        if os.path.exists(unit):
            subprocess.run(["systemctl", "--user", "disable", "--now", OLD_SYSTEMD_UNIT_NAME],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.remove(unit)
            subprocess.run(["systemctl", "--user", "daemon-reload"])
            print("Removed the old systemd service %s" % OLD_SYSTEMD_UNIT_NAME)
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    old_cli = os.path.join(home, ".local", "bin", "aiusage")
    if os.path.islink(old_cli):
        os.remove(old_cli)
    shutil.rmtree(os.path.join(os.path.expanduser(data), "aiusage"), ignore_errors=True)


def install(args, cfg, show_pairing=True):
    if sys.platform.startswith("linux") and not shutil.which("systemctl"):
        print("systemd not found. Run `meterkat serve` under your init system (or in tmux) instead.")
        return 1
    remove_old_install()
    if args.port and args.port != cfg["port"]:
        cfg["port"] = args.port
        save_config(cfg)
        print("Saved port %d to %s" % (args.port, CONFIG_PATH))
    if args.host not in ("0.0.0.0", "::", "127.0.0.1", "::1"):
        print("Warning: with --host %s the Mac app and `meterkat status` (127.0.0.1) can't reach it."
              % args.host)
    if IS_MAC:
        os.makedirs(os.path.dirname(LAUNCHD_LOG), exist_ok=True)
        plist = {
            "Label": LAUNCHD_LABEL,
            "ProgramArguments": _service_args(args),
            "RunAtLoad": True,
            "KeepAlive": True,
            "StandardOutPath": LAUNCHD_LOG,
            "StandardErrorPath": LAUNCHD_LOG,
            "EnvironmentVariables": _service_env(),
            "ProcessType": "Background",
        }
        code = _launchd_load(LAUNCHD_LABEL, LAUNCHD_PLIST, plist)
        if code != 0:
            print("launchctl bootstrap failed (exit %d). Plist: %s" % (code, LAUNCHD_PLIST))
            return 1
        print("Installed LaunchAgent %s" % LAUNCHD_PLIST)
        print("Logs: %s" % LAUNCHD_LOG)
        if not args.no_menubar:
            install_menubar()
    elif sys.platform.startswith("linux"):
        if not os.environ.get("XDG_RUNTIME_DIR"):
            print("Your user's systemd isn't running (no login session, and linger is off), so the")
            print("service can't be installed. Turn on linger, then run `meterkat install` again:")
            print("  sudo loginctl enable-linger $USER")
            return 1
        os.makedirs(os.path.dirname(SYSTEMD_UNIT), exist_ok=True)
        env_lines = "".join('Environment="%s=%s"\n' % (k, v) for k, v in _service_env().items())
        exec_start = " ".join('"%s"' % a if " " in a else a for a in _service_args(args))
        unit = (
            "[Unit]\n"
            "Description=Meterkat companion\n"
            "After=network-online.target\n\n"
            "[Service]\n"
            "ExecStart=%s\n"
            "%s"
            "Restart=always\n"
            "RestartSec=10\n\n"
            "[Install]\n"
            "WantedBy=default.target\n" % (exec_start, env_lines)
        )
        with open(SYSTEMD_UNIT, "w") as f:
            f.write(unit)
        subprocess.run(["systemctl", "--user", "daemon-reload"])
        subprocess.run(["systemctl", "--user", "enable", SYSTEMD_UNIT_NAME])
        # restart (not just start) so a reinstall picks up the new script
        res = subprocess.run(["systemctl", "--user", "restart", SYSTEMD_UNIT_NAME])
        if res.returncode != 0:
            print("systemctl restart failed (exit %d). Unit: %s" % (res.returncode, SYSTEMD_UNIT))
            return 1
        print("Installed systemd user service %s" % SYSTEMD_UNIT)
        print("Logs: journalctl --user -u %s -f" % SYSTEMD_UNIT_NAME)
        if not linger_enabled():
            print("To keep it running while logged out: sudo loginctl enable-linger $USER")
    else:
        print("install is supported on macOS and Linux only.")
        return 1
    for var, pid in (("OPENROUTER_API_KEY", "openrouter"), ("ZAI_API_KEY", "zai"),
                    ("DEEPSEEK_API_KEY", "deepseek")):
        if (os.environ.get(var) or "").strip() and not cfg.get(API_KEY_KEYS[pid]):
            print("")
            print("$%s is set in this shell, but the background service can't see it. Save it:" % var)
            print("  printenv %s | meterkat config set-key %s" % (var, pid))
    if show_pairing:
        print_current_pairing(cfg, cfg["port"], args.host)
    return 0


def uninstall(args, cfg):
    if IS_MAC:
        domain = "gui/%d" % os.getuid()
        for label, path in ((LAUNCHD_LABEL, LAUNCHD_PLIST), (MENUBAR_LABEL, MENUBAR_PLIST)):
            subprocess.run(["launchctl", "bootout", domain + "/" + label],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if os.path.exists(path):
                os.remove(path)
            print("Removed LaunchAgent %s" % label)
        for app in [LEGACY_MENUBAR_APP] + MAC_APP_PATHS:
            if not os.path.isdir(app):
                continue
            quit_app(app)
            if args.purge:
                shutil.rmtree(app)
                print("Deleted %s" % app)
    elif sys.platform.startswith("linux"):
        has_systemctl = bool(shutil.which("systemctl"))
        if has_systemctl:
            subprocess.run(["systemctl", "--user", "disable", "--now", SYSTEMD_UNIT_NAME],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.exists(SYSTEMD_UNIT):
            os.remove(SYSTEMD_UNIT)
        if has_systemctl:
            subprocess.run(["systemctl", "--user", "daemon-reload"])
        print("Removed systemd user service %s" % SYSTEMD_UNIT_NAME)
    else:
        print("uninstall is supported on macOS and Linux only.")
        return 1
    print("Config (token) kept at %s." % CONFIG_PATH)
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def build_parser():
    # Shared flags, accepted before or after the command. SUPPRESS keeps a
    # subcommand from overwriting a value given before it; main() fills defaults.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--host", default=argparse.SUPPRESS, help="bind address (default 0.0.0.0)")
    common.add_argument("--port", type=int, default=argparse.SUPPRESS,
                        help="port (default: value in config.json, initially %d)" % DEFAULT_PORT)
    common.add_argument("--cache-seconds", type=int, default=argparse.SUPPRESS,
                        help="snapshot cache lifetime in seconds (default %d)" % DEFAULT_CACHE_SECONDS)
    common.add_argument("--poll-seconds", type=int, default=argparse.SUPPRESS,
                        help="background poll interval for the usage history, 0 disables (default %d)"
                        % DEFAULT_POLL_SECONDS)

    parser = argparse.ArgumentParser(
        prog="meterkat", parents=[common],
        description="Serve Claude, ChatGPT Codex, OpenCode Go, OpenRouter, GitHub Copilot, Gemini CLI, "
                    "Cursor, Z.ai and DeepSeek usage to the Meterkat apps.")
    parser.add_argument("--version", action="version", version="meterkat " + VERSION)
    parser.add_argument("--print-pairing", action="store_true", help=argparse.SUPPRESS)  # 1.0 flag
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.add_parser("serve", parents=[common], help="serve usage to the app (default)")
    p = sub.add_parser("pair", parents=[common], help="print the pairing link and QR code")
    p.add_argument("--png", metavar="PATH", help="also write the QR code to a PNG")
    p.add_argument("--owner", action="store_true",
                   help="make an owner link: the device it pairs can also list and revoke this machine's devices")
    p = sub.add_parser("devices", parents=[common],
                       help="list the devices paired with this companion, or revoke one")
    p.add_argument("--json", action="store_true", help="print JSON (never includes a token)")
    dsub = p.add_subparsers(dest="devices_action", metavar="action")
    d = dsub.add_parser("list", help="list paired devices, newest first (default)")
    d.add_argument("--json", action="store_true", help="print JSON")
    d = dsub.add_parser("revoke", help="revoke one device by id or name; it stops working at once")
    d.add_argument("device", help="the ID or name shown by `meterkat devices`")
    d.add_argument("--yes", "-y", action="store_true", help="don't ask for confirmation")
    sub.add_parser("once", help="fetch usage once and print the JSON snapshot")
    p = sub.add_parser("usage", parents=[common], help="print the running companion's usage JSON")
    p.add_argument("--provider", choices=PROVIDER_IDS, help="include only this provider in the output")
    p.add_argument("--refresh", action="store_true", help="request a fresh snapshot (rate-limited by the service)")
    p = sub.add_parser("history", parents=[common],
                       help="print usage history and per-window rate projections")
    p.add_argument("--provider", choices=PROVIDER_IDS, help="include only this provider")
    p.add_argument("--window", help="include only this window id, such as five_hour or weekly")
    p = sub.add_parser("watch", parents=[common],
                       help="wait until a provider's usage crosses a threshold (exit 3), for agent runs")
    p.add_argument("--provider", choices=PROVIDER_IDS, default="claude", help="provider to watch (default claude)")
    p.add_argument("--at", action="append", metavar="[KIND=]PCT",
                   help="threshold in percent used: 85 for every kind, or session=85, weekly=95, "
                        "model=off; repeatable (default session=85, others 95)")
    p.add_argument("--once", action="store_true", help="check once: exit 0 below every threshold, 3 at one, "
                                                         "4 with no usable reading")
    p.add_argument("--json", action="store_true", help="print one JSON event per line")
    sub.add_parser("status", parents=[common], help="show whether the service is installed and running")
    p = sub.add_parser("setup", parents=[common],
                       help="choose providers and keys, install the service, and pair (interactive)")
    p.add_argument("--yes", action="store_true", help="take every suggested answer without asking")
    p.add_argument("--no-menubar", action="store_true", help="macOS: don't open the Meterkat app at login")
    p = sub.add_parser("detect", help="show which providers this machine has credentials for (no network)")
    p.add_argument("--json", action="store_true", help="print JSON")
    sub.add_parser("restart", help="restart the background service")
    p = sub.add_parser("update", help="pull the checkout it was installed from, reinstall, and restart the service")
    p.add_argument("--from", dest="source", metavar="PATH",
                   help="install from this checkout (default: the one install.sh last ran from)")
    p.add_argument("--no-pull", action="store_true", help="don't run git pull first")
    p.add_argument("--force", action="store_true", help="reinstall even when nothing changed")
    p = sub.add_parser("config", parents=[common],
                       help="show the config, override URLs, turn providers on/off, save API keys, "
                            "rotate the token")
    csub = p.add_subparsers(dest="config_action", metavar="action")
    csub.add_parser("show", help="show the config with the token masked (default)")
    s = csub.add_parser("set", help="override the local or remote URL used in pairing links")
    s.add_argument("key", choices=sorted(URL_KEYS))
    s.add_argument("url")
    s = csub.add_parser("unset", help="go back to the auto-detected URL")
    s.add_argument("key", choices=sorted(URL_KEYS))
    s = csub.add_parser("disable", help="stop fetching and serving a provider")
    s.add_argument("provider", choices=PROVIDER_IDS)
    s = csub.add_parser("enable", help="fetch and serve a disabled provider again")
    s.add_argument("provider", choices=PROVIDER_IDS)
    s = csub.add_parser("set-key", help="save a provider API key for the service (prompts, or reads stdin)")
    s.add_argument("provider", choices=sorted(API_KEY_KEYS))
    s = csub.add_parser("unset-key", help="delete a saved provider API key")
    s.add_argument("provider", choices=sorted(API_KEY_KEYS))
    csub.add_parser("rotate-token", help="generate a new bearer token (re-pair the iPhone afterwards)")
    s = csub.add_parser("announce", help="turn the local-network announcement (_meterkat._tcp) on or off")
    s.add_argument("state", choices=["on", "off"])
    p = sub.add_parser("install", parents=[common],
                       help="run at login (launchd on macOS, systemd --user on Linux)")
    p.add_argument("--no-menubar", action="store_true", help="macOS: don't open the Meterkat app at login")
    p = sub.add_parser("uninstall", help="remove the service (and the Mac app's login item on macOS)")
    p.add_argument("--purge", action="store_true", help="macOS: also delete the Meterkat app")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    for name, default in (("host", "0.0.0.0"), ("port", None), ("cache_seconds", DEFAULT_CACHE_SECONDS),
                          ("poll_seconds", DEFAULT_POLL_SECONDS)):
        if not hasattr(args, name):
            setattr(args, name, default)
    cfg = load_config()
    if sys.platform.startswith("linux"):
        ensure_user_bus_env()
    command = "pair" if args.print_pairing else (args.command or "serve")
    handlers = {
        "serve": serve,
        "pair": cmd_pair,
        "devices": cmd_devices,
        "once": cmd_once,
        "usage": cmd_usage,
        "history": cmd_history,
        "watch": cmd_watch,
        "status": cmd_status,
        "detect": cmd_detect,
        "setup": cmd_setup,
        "restart": cmd_restart,
        "update": cmd_update,
        "config": cmd_config,
        "install": install,
        "uninstall": uninstall,
    }
    return handlers[command](args, cfg) or 0


if __name__ == "__main__":
    sys.exit(main())
