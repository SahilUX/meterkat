import json
import os
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone

import api_cost


NOW = datetime(2026, 10, 1, tzinfo=timezone.utc).timestamp()


def write_rows(root, name, rows):
    os.makedirs(root, exist_ok=True)
    path = os.path.join(root, name)
    with open(path, "w") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")
    os.utime(path, (NOW, NOW))


class APICostTests(unittest.TestCase):
    def test_fable_5_2_is_not_fable_5(self):
        self.assertEqual(api_cost.price_key("claude-fable-5-2", api_cost.CLAUDE_RATES), "claude-fable-5-2")
        self.assertEqual(api_cost.price_key("claude-fable-5", api_cost.CLAUDE_RATES), "claude-fable-5")
        cost = api_cost.claude_cost("claude-fable-5-2", (1_000_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000))
        self.assertAlmostEqual(cost, 8 + .2 + 10 + 16 + 40)

    def test_haiku_5_5_is_priced_by_prompt_length(self):
        short = api_cost.claude_cost("claude-haiku-5-5", (60_000, 20_000, 10_000, 10_000, 1_000_000))
        self.assertAlmostEqual(short, (60_000 * .1 + 20_000 * .01 + 10_000 * .125 + 10_000 * .2 + 1_000_000 * .5) / 1e6)
        # Cache reads and writes count toward the threshold: 100,001 tokens is over.
        long = api_cost.claude_cost("claude-haiku-5-5", (1, 100_000, 0, 0, 1_000_000))
        self.assertAlmostEqual(long, (1 * .5 + 100_000 * .05 + 1_000_000 * 2.5) / 1e6)
        edge = api_cost.claude_cost("claude-haiku-5-5", (0, 100_000, 0, 0, 0))
        self.assertAlmostEqual(edge, 100_000 * .01 / 1e6)
        self.assertAlmostEqual(api_cost.claude_cost("claude-haiku-4-5", (200_000, 0, 0, 0, 0)), .2)

    def test_sonnet_5_5_cache_read(self):
        self.assertAlmostEqual(api_cost.claude_cost("claude-sonnet-5-5", (0, 1_000_000, 0, 0, 0)), .1)

    def test_price_key_only_strips_date_suffixes(self):
        rates = api_cost.CLAUDE_RATES
        self.assertEqual(api_cost.price_key("claude-haiku-4-5-20251001", rates), "claude-haiku-4-5")
        self.assertEqual(api_cost.price_key("gpt-5.5-2026-04-23", api_cost.OPENAI_RATES), "gpt-5.5")
        self.assertIsNone(api_cost.price_key("claude-haiku-4-5-2", rates))
        self.assertIsNone(api_cost.price_key("claude-opus-4-8-1", rates))
        self.assertIsNone(api_cost.price_key("claude-haiku-4-5-202510", rates))

    def test_claude_streaming_deduplicates_and_prices_cache(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            codex = os.path.join(root, "codex")
            usage = {"input_tokens": 1_000, "cache_read_input_tokens": 2_000,
                     "cache_creation_input_tokens": 4_000,
                     "cache_creation": {"ephemeral_5m_input_tokens": 3_000,
                                        "ephemeral_1h_input_tokens": 1_000},
                     "output_tokens": 100}
            def row(output):
                return {"type": "assistant", "timestamp": "2026-09-30T00:00:00Z",
                        "message": {"id": "msg-1", "model": "claude-opus-5-5",
                                    "usage": dict(usage, output_tokens=output)}}
            write_rows(claude, "session.jsonl", [row(10), row(100)])
            result = api_cost.estimates(NOW, claude, codex)["claude"]
            expected = (1000 * 4 + 2000 * .2 + 3000 * 5 + 1000 * 8 + 100 * 20) / 1_000_000
            self.assertAlmostEqual(result["weekUSD"], expected, places=4)
            self.assertEqual(result["priced"], 1)
            self.assertEqual(result["weekTokens"], 1_000 + 2_000 + 4_000 + 100)

    def test_codex_cumulative_totals_and_unknown_models(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            codex = os.path.join(root, "codex")
            def event(total, stamp="2026-09-30T00:00:00Z"):
                return {"type": "event_msg", "timestamp": stamp,
                        "payload": {"type": "token_count", "info": {"total_token_usage": total}}}
            first = {"input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 100}
            second = {"input_tokens": 1500, "cached_input_tokens": 600, "output_tokens": 150}
            write_rows(codex, "rollout.jsonl", [
                {"type": "turn_context", "payload": {"model": "gpt-6-sol"}},
                event(first), event(first), event(second),
                {"type": "turn_context", "payload": {"model": "unknown-model"}},
                event({"input_tokens": 1600, "cached_input_tokens": 600, "output_tokens": 160})])
            result = api_cost.estimates(NOW, claude, codex)["openai"]
            expected = (900 * 2 + 600 * .2 + 150 * 10) / 1_000_000
            self.assertAlmostEqual(result["weekUSD"], expected, places=4)
            self.assertEqual(result["priced"], 2)
            self.assertEqual(result["unpriced"], 1)
            # The unpriced model's 100 input and 10 output tokens still count.
            self.assertEqual(result["monthTokens"], 1600 + 160)

    def test_periods_split_tokens_and_models(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            codex = os.path.join(root, "codex")
            def row(key, stamp, model, usage):
                return {"type": "assistant", "timestamp": stamp,
                        "message": {"id": key, "model": model, "usage": usage}}
            write_rows(claude, "session.jsonl", [
                row("today", "2026-09-30T12:00:00Z", "claude-sonnet-5-5-20260901",
                    {"input_tokens": 10, "cache_read_input_tokens": 20,
                     "cache_creation_input_tokens": 30, "output_tokens": 40}),
                row("old", "2026-08-01T00:00:00Z", "claude-opus-5-5", {"output_tokens": 1000}),
                row("mystery", "2026-09-30T13:00:00Z", "other-model", {"output_tokens": 5})])
            result = api_cost.estimates(NOW, claude, codex)["claude"]
            day, month, every = (result["periods"][p] for p in ("day", "month", "all"))
            self.assertEqual((day["input"], day["output"], day["cacheRead"], day["cacheWrite"]), (10, 45, 20, 30))
            self.assertEqual((day["priced"], day["unpriced"]), (1, 1))
            self.assertEqual(day["models"][0], {"model": "claude-sonnet-5-5", "tokens": 100,
                                                "usd": round((10 * 2 + 20 * .2 + 30 * 2.5 + 40 * 10) / 1e6, 4)})
            self.assertEqual(day["models"][1], {"model": "other-model", "tokens": 5, "usd": None})
            self.assertEqual(month["tokens"], 105)
            # Logs past 30 days only count toward all time.
            self.assertEqual(every["tokens"], 1105)
            self.assertEqual(result["since"], "2026-08-01T00:00:00Z")
            self.assertEqual(result["monthTokens"], 105)


    def test_ledger_keeps_days_whose_logs_were_deleted(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            codex = os.path.join(root, "codex")
            ledger = os.path.join(root, "state", "costs.json")
            def row(key, stamp):
                return {"type": "assistant", "timestamp": stamp,
                        "message": {"id": key, "model": "claude-opus-5-5", "usage": {"output_tokens": 100}}}
            write_rows(claude, "old.jsonl", [row("a", "2026-08-01T00:00:00Z")])
            write_rows(claude, "new.jsonl", [row("b", "2026-09-30T00:00:00Z")])
            api_cost.estimates(NOW, claude, codex, ledger_path=ledger)
            os.remove(os.path.join(claude, "old.jsonl"))
            result = api_cost.estimates(NOW, claude, codex, ledger_path=ledger)["claude"]
            self.assertEqual(result["periods"]["all"]["tokens"], 200)
            self.assertEqual(result["periods"]["all"]["priced"], 2)
            self.assertEqual(result["since"], "2026-08-01T00:00:00Z")

    def test_stats_cache_fills_days_before_the_logs(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            codex = os.path.join(root, "codex")
            stats = os.path.join(root, "stats-cache.json")
            write_rows(claude, "new.jsonl", [{"type": "assistant", "timestamp": "2026-09-30T00:00:00Z",
                                              "message": {"id": "b", "model": "claude-opus-5-5",
                                                          "usage": {"output_tokens": 100}}}])
            with open(stats, "w") as stream:
                json.dump({"modelUsage": {"claude-opus-5-5": {"inputTokens": 0, "outputTokens": 1,
                                                              "cacheReadInputTokens": 3,
                                                              "cacheCreationInputTokens": 0}},
                           "dailyModelTokens": [
                               {"date": "2026-07-01", "tokensByModel": {"claude-opus-5-5": 4000}},
                               # Covered by the logs, so not counted twice.
                               {"date": "2026-09-30", "tokensByModel": {"claude-opus-5-5": 999}}]}, stream)
            result = api_cost.estimates(NOW, claude, codex, claude_stats=stats)["claude"]
            every = result["periods"]["all"]
            self.assertEqual((every["output"], every["cacheRead"]), (1100, 3000))
            self.assertAlmostEqual(every["usd"], (1100 * 20 + 3000 * .2) / 1e6, places=4)
            self.assertEqual(result["estimatedThrough"], "2026-07-01T23:59:59Z")
            self.assertEqual(result["since"], "2026-07-01T00:00:00Z")

    def test_unchanged_files_are_not_read_again(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            codex = os.path.join(root, "codex")
            def row(key, stamp):
                return {"type": "assistant", "timestamp": stamp,
                        "message": {"id": key, "model": "claude-opus-5-5", "usage": {"output_tokens": 100}}}
            write_rows(claude, "a.jsonl", [row("a", "2026-09-29T00:00:00Z")])
            write_rows(claude, "b.jsonl", [row("b", "2026-09-30T00:00:00Z")])
            caches = {}
            first = api_cost.estimates(NOW, claude, codex, caches=caches)["claude"]
            with mock.patch.object(api_cost, "file_rows", wraps=api_cost.file_rows) as rows:
                again = api_cost.estimates(NOW, claude, codex, caches=caches)["claude"]
                self.assertEqual(rows.call_count, 0)
                self.assertEqual(again, first)
                # Only the file that grew is read.
                write_rows(claude, "b.jsonl", [row("b", "2026-09-30T00:00:00Z"), row("c", "2026-09-30T01:00:00Z")])
                grown = api_cost.estimates(NOW, claude, codex, caches=caches)["claude"]
                self.assertEqual(rows.call_count, 1)
            self.assertEqual(grown["periods"]["all"]["tokens"], 300)
            os.remove(os.path.join(claude, "a.jsonl"))
            api_cost.estimates(NOW, claude, codex, caches=caches)
            self.assertEqual(sorted(os.path.basename(p) for p in caches["claude"].files), ["b.jsonl"])

    def test_message_repeated_across_files_counts_once(self):
        with tempfile.TemporaryDirectory() as root:
            claude = os.path.join(root, "claude")
            def row(output):
                return {"type": "assistant", "timestamp": "2026-09-30T00:00:00Z",
                        "message": {"id": "m", "model": "claude-opus-5-5", "usage": {"output_tokens": output}}}
            write_rows(claude, "a.jsonl", [row(10)])
            write_rows(claude, "b.jsonl", [row(100)])
            result = api_cost.estimates(NOW, claude, os.path.join(root, "codex"))["claude"]
            self.assertEqual(result["periods"]["all"]["tokens"], 100)


if __name__ == "__main__":
    unittest.main()
