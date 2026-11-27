"""Estimate standard API cost from local Claude Code and Codex token logs.

Prices are USD per million tokens, checked 2026-11-23 against
https://platform.claude.com/docs/en/about-claude/pricing (OpenAI: 2026-10-09,
https://developers.openai.com/api/docs/pricing ).
"""

import glob
import tempfile
import json
import math
import os
import re
import sys
import time
from datetime import datetime, timezone

DAY = 86400
# Claude: input, cache read, 5m write, 1h write, output.
CLAUDE_RATES = {
    "claude-fable-5-2": (8, .2, 10, 16, 40),
    "claude-fable-5-1": (10, .25, 12.5, 20, 50),
    "claude-fable-5": (10, 1, 12.5, 20, 50),
    "claude-opus-5-5": (4, .2, 5, 8, 20),
    "claude-opus-5": (5, .5, 6.25, 10, 25),
    "claude-opus-4-8": (5, .5, 6.25, 10, 25),
    "claude-sonnet-5-5": (2, .1, 2.5, 4, 10),
    "claude-sonnet-5": (2, .2, 2.5, 4, 10),
    "claude-haiku-5-5": (.1, .01, .125, .2, .5),
    "claude-haiku-4-5": (1, .1, 1.25, 2, 5),
}
# Haiku 5.5 prices each request by its prompt length (input + cache reads + cache writes).
# A prompt over the threshold uses these rates for all of its tokens.
CLAUDE_LONG_PROMPT = 100_000
CLAUDE_LONG_RATES = {
    "claude-haiku-5-5": (.5, .05, .625, 1, 2.5),
}
# OpenAI: input, cached input, cache write, output.
OPENAI_RATES = {
    "gpt-6.1-sol": (2, .1, 2.5, 10),
    "gpt-6-astra": (10, 1, 12.5, 50),
    "gpt-6-sol": (2, .2, 2.5, 10),
    "gpt-6-luna": (.1, .01, .125, .5),
    "gpt-5.6-sol": (4, .4, 5, 20),
    "gpt-5.6-terra": (2, .2, 2.5, 12),
    "gpt-5.6-luna": (.2, .02, .25, 1.2),
    "gpt-5.5": (5, .5, 6.25, 30),
    # No cache-write price is listed; writes are billed as input.
    "gpt-5.3-codex": (1.75, .175, 1.75, 14),
}

DATE_SUFFIX = re.compile(r"-(\d{8}|\d{4}-\d{2}-\d{2})")


def price_key(model, prices):
    """The listed model a logged name belongs to: itself, or itself plus a date suffix
    (-YYYYMMDD or -YYYY-MM-DD). A version suffix such as -2 is a different model."""
    if not isinstance(model, str):
        return None
    for name in sorted(prices, key=len, reverse=True):
        if model == name or (model.startswith(name) and DATE_SUFFIX.fullmatch(model[len(name):])):
            return name
    return None


def rate_for(model, prices):
    key = price_key(model, prices)
    return prices[key] if key else None


def model_name(model, prices):
    return price_key(model, prices) or (model if isinstance(model, str) and model else "unknown")


def count(value):
    if isinstance(value, bool):
        return 0
    try:
        number = float(value)
        return max(number, 0) if math.isfinite(number) else 0
    except (TypeError, ValueError):
        return 0


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def claude_tokens(usage):
    cache = usage.get("cache_creation")
    if not isinstance(cache, dict):
        cache = {}
    write5 = count(cache.get("ephemeral_5m_input_tokens"))
    write1 = count(cache.get("ephemeral_1h_input_tokens"))
    # Older logs only carry the combined cache-write count. The 5m rate is
    # the default; this case is an approximation.
    write5 += max(0, count(usage.get("cache_creation_input_tokens")) - write5 - write1)
    return (count(usage.get("input_tokens")), count(usage.get("cache_read_input_tokens")),
            write5, write1, count(usage.get("output_tokens")))


def claude_cost(model, tokens):
    """`tokens` is claude_tokens(usage): input, cache read, 5m write, 1h write, output."""
    rates = rate_for(model, CLAUDE_RATES)
    if not rates:
        return None
    long_rates = CLAUDE_LONG_RATES.get(price_key(model, CLAUDE_RATES))
    if long_rates and sum(tokens[:4]) > CLAUDE_LONG_PROMPT:
        rates = long_rates
    return sum(n * rate for n, rate in zip(tokens, rates)) / 1_000_000


def codex_tokens(usage):
    total = count(usage.get("input_tokens"))
    cached = count(usage.get("cached_input_tokens"))
    written = count(usage.get("cache_write_input_tokens"))
    return (max(0, total - cached - written), cached, written,
            count(usage.get("output_tokens")))


def codex_cost(model, usage):
    rates = rate_for(model, OPENAI_RATES)
    if not rates:
        return None
    return sum(n * rate for n, rate in zip(codex_tokens(usage), rates)) / 1_000_000


def log_files(root, cutoff):
    for path in glob.iglob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(path) >= cutoff:
                yield path
        except OSError:
            continue


def file_rows(path):
    """Rows of one log file. An OSError mid-read propagates, so a half-read file is never cached."""
    with open(path, "r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                row = json.loads(line)
                if isinstance(row, dict):
                    yield row
            except (ValueError, TypeError):
                continue


class FileCache:
    """What each log file parsed to, so a file that hasn't changed is never read again.
    The logs grow to gigabytes, and a full read every few minutes starves the machine."""

    def __init__(self):
        self.files = {}  # path -> ((mtime_ns, size), parsed)

    def parse(self, path, parser):
        try:
            stat = os.stat(path)
        except OSError:
            return None
        key = (stat.st_mtime_ns, stat.st_size)
        hit = self.files.get(path)
        if hit and hit[0] == key:
            return hit[1]
        try:
            parsed = parser(path)
        except OSError:
            return None  # unreadable now; try again next scan
        self.files[path] = (key, parsed)
        return parsed

    def forget_except(self, paths):
        for path in set(self.files) - set(paths):
            del self.files[path]


def parsed_files(root, cutoff, parser, cache):
    """Yield (path, parsed) for every log file under `root` modified since `cutoff`."""
    cache = FileCache() if cache is None else cache
    seen = []
    for path in log_files(root, cutoff):
        seen.append(path)
        parsed = cache.parse(path, parser)
        if parsed is not None:
            yield path, parsed
    cache.forget_except(seen)


def claude_file_messages(path):
    # Streaming repeats message IDs as output grows. Use the largest count.
    messages = {}
    for row in file_rows(path):
        if row.get("type") != "assistant":
            continue
        message = row.get("message") or {}
        if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
            continue
        when = timestamp(row.get("timestamp"))
        if when is None:
            continue
        key = message.get("id") or row.get("uuid")
        if not key:
            continue
        tokens = claude_tokens(message["usage"])
        old = messages.get(key)
        if old is None or tokens[4] >= old[2][4]:
            model = message.get("model")
            messages[key] = (when, sys.intern(model) if isinstance(model, str) else model, tokens)
    return messages


def claude_entries(root, cutoff, cache=None):
    messages = {}
    for _, found in parsed_files(root, cutoff, claude_file_messages, cache):
        for key, entry in found.items():
            if entry[0] < cutoff:
                continue
            old = messages.get(key)
            if old is None or entry[2][4] >= old[2][4]:
                messages[key] = entry
    for when, model, tokens in messages.values():
        fresh, read, write5, write1, output = tokens
        yield when, model_name(model, CLAUDE_RATES), claude_cost(model, tokens), (fresh, output, read, write5 + write1)


def codex_file_entries(path):
    previous = {}
    model = None
    entries = []
    fields = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens")
    for row in file_rows(path):
        payload = row.get("payload") or {}
        if not isinstance(payload, dict):
            continue
        if row.get("type") == "turn_context":
            model = payload.get("model") or model
        if row.get("type") != "event_msg" or payload.get("type") != "token_count":
            continue
        info = payload.get("info")
        total = info.get("total_token_usage") if isinstance(info, dict) else None
        if not isinstance(total, dict):
            continue
        current = {field: count(total.get(field)) for field in fields}
        delta = {field: max(0, current[field] - previous.get(field, 0)) for field in fields}
        previous = current
        when = timestamp(row.get("timestamp"))
        if when is not None and any(delta.values()):
            fresh, cached, written, output = codex_tokens(delta)
            entries.append((when, model_name(model, OPENAI_RATES), codex_cost(model, delta),
                            (fresh, output, cached, written)))
    return entries


def codex_entries(root, cutoff, cache=None):
    for _, entries in parsed_files(root, cutoff, codex_file_entries, cache):
        for entry in entries:
            if entry[0] >= cutoff:
                yield entry


# Period name -> length in seconds; None is everything in the ledger.
PERIODS = {"day": DAY, "week": 7 * DAY, "month": 30 * DAY, "all": None}
MAX_MODELS = 8


class Totals:
    def __init__(self):
        self.usd = 0.0
        self.parts = [0, 0, 0, 0]  # input, output, cache read, cache write
        self.priced = self.unpriced = 0
        self.models = {}

    def add(self, model, parts, usd, priced, unpriced):
        """`usd` is None when none of these requests had a listed price."""
        tokens = sum(parts)
        for i, n in enumerate(parts):
            self.parts[i] += n
        self.usd += usd or 0
        self.priced += priced
        self.unpriced += unpriced
        if tokens:
            entry = self.models.setdefault(model, [0, None])
            entry[0] += tokens
            if usd is not None:
                entry[1] = (entry[1] or 0) + usd

    def add_entry(self, model, cost, parts):
        self.add(model, parts, cost, int(cost is not None), int(cost is None))

    def payload(self):
        models = sorted(self.models.items(), key=lambda item: item[1][0], reverse=True)[:MAX_MODELS]
        return {"usd": round(self.usd, 4), "tokens": int(sum(self.parts)),
                "input": int(self.parts[0]), "output": int(self.parts[1]),
                "cacheRead": int(self.parts[2]), "cacheWrite": int(self.parts[3]),
                "priced": self.priced, "unpriced": self.unpriced,
                "models": [{"model": name, "tokens": int(tokens),
                            "usd": None if usd is None else round(usd, 4)}
                           for name, (tokens, usd) in models]}


def day_of(when):
    return time.strftime("%Y-%m-%d", time.gmtime(when))


def day_total(models):
    return sum(sum(row[:4]) for row in models.values())


def add_to_day(days, when, model, cost, parts):
    """Ledger rows: {day: {model: [input, output, read, write, usd or None, priced, unpriced]}}."""
    row = days.setdefault(day_of(when), {}).setdefault(model, [0, 0, 0, 0, None, 0, 0])
    for i, n in enumerate(parts):
        row[i] += int(n)
    if cost is None:
        row[6] += 1
    else:
        row[4] = (row[4] or 0) + cost
        row[5] += 1


def claude_stats_days(path):
    """Days from Claude Code's /stats cache, which outlives the logs Claude Code deletes.
    It keeps one token total per model per day, so each day is split into
    input, output and cache tokens by that model's overall mix. Requests aren't kept,
    so long-prompt rates (CLAUDE_LONG_RATES) never apply here."""
    data = None
    try:
        with open(path, "r", encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    mixes = {}
    for model, usage in (data.get("modelUsage") or {}).items():
        if isinstance(usage, dict):
            mixes[model] = [count(usage.get(key)) for key in
                            ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")]
    days = {}
    for entry in data.get("dailyModelTokens") or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("date"), str):
            continue
        for model, tokens in (entry.get("tokensByModel") or {}).items():
            tokens = count(tokens)
            mix = mixes.get(model) or [0, 0, 0, 0]
            total = sum(mix)
            parts = [tokens * n / total for n in mix] if total else [0, tokens, 0, 0]
            rates = rate_for(model, CLAUDE_RATES)
            usd = None
            if rates:
                # Cache writes at the 5-minute rate, as in older logs.
                usd = sum(n * r for n, r in zip((parts[0], parts[2], parts[3], 0, parts[1]), rates)) / 1_000_000
            row = days.setdefault(entry["date"], {}).setdefault(model_name(model, CLAUDE_RATES), [0, 0, 0, 0, None, 0, 0])
            for i, n in enumerate(parts):
                row[i] += int(round(n))
            if usd is not None:
                row[4] = (row[4] or 0) + usd
    return days


def load_ledger(path):
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as stream:
            data = json.load(stream)
        return data.get("providers") or {} if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_ledger(path, providers):
    if not path:
        return
    directory = os.path.dirname(path)
    try:
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".costs-")
        with os.fdopen(fd, "w") as stream:
            json.dump({"version": 1, "providers": providers}, stream, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass


def estimates(now=None, claude_root=None, codex_root=None, ledger_path=None, claude_stats=None, caches=None):
    """Return only totals, coverage and model names; never return log content.

    All time comes from a ledger of daily totals kept at `ledger_path`, so it
    still counts days whose logs the CLI has since deleted. `caches` is a dict the
    caller keeps between calls, so later scans only read the files that changed."""
    now = time.time() if now is None else now
    claude_dir = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    sources = {
        "claude": (claude_root or os.path.join(claude_dir, "projects"), claude_entries),
        "openai": (codex_root or os.path.expanduser("~/.codex/sessions"), codex_entries),
    }
    ledger = load_ledger(ledger_path)
    caches = {} if caches is None else caches
    result = {}
    for provider, (root, reader) in sources.items():
        totals = {period: Totals() for period in PERIODS if PERIODS[period]}
        scanned = {}
        for when, model, cost, parts in reader(root, 0, caches.setdefault(provider, FileCache())):
            # Zero-token entries, such as Claude Code's <synthetic> messages, aren't requests.
            if when > now or not sum(parts):
                continue
            add_to_day(scanned, when, model, cost, parts)
            for period, length in PERIODS.items():
                if length and when >= now - length:
                    # Tokens count for every model, priced or not.
                    totals[period].add_entry(model, cost, parts)

        saved = ledger.setdefault(provider, {})
        days = saved.setdefault("days", {})
        estimated = set(saved.get("estimatedDays") or [])
        # A day's logs only shrink when the CLI deletes them, so keep the larger count.
        for day, models in scanned.items():
            if day not in days or day in estimated or day_total(models) >= day_total(days[day]):
                days[day] = models
                estimated.discard(day)
        if provider == "claude":
            first_logged = min(scanned) if scanned else None
            if claude_stats is None and claude_root is None:
                claude_stats = os.path.join(claude_dir, "stats-cache.json")
            stats = claude_stats_days(claude_stats) if claude_stats else {}
            for day, models in stats.items():
                if day not in days and (first_logged is None or day < first_logged):
                    days[day] = models
                    estimated.add(day)
        saved["estimatedDays"] = sorted(estimated)

        everything = Totals()
        for models in days.values():
            for model, row in models.items():
                everything.add(model, row[:4], row[4], row[5], row[6])
        totals["all"] = everything
        if not days:
            continue
        week, month = totals["week"], totals["month"]
        result[provider] = {
            # Read by apps before 2.2.
            "weekUSD": round(week.usd, 4), "monthUSD": round(month.usd, 4),
            "weekTokens": int(sum(week.parts)), "monthTokens": int(sum(month.parts)),
            "priced": month.priced, "unpriced": month.unpriced,
            "since": min(days) + "T00:00:00Z",
            "periods": {period: totals[period].payload() for period in PERIODS},
        }
        if estimated:
            result[provider]["estimatedThrough"] = max(estimated) + "T23:59:59Z"
    save_ledger(ledger_path, ledger)
    return result
