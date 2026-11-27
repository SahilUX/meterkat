import contextlib
import io
import json
import os
import tempfile
import unittest
from unittest import mock

import meterkat


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = {
            "generatedAt": "2026-10-13T00:00:00Z",
            "host": "test-host",
            "companionVersion": meterkat.VERSION,
            "providers": [
                {"id": "claude", "status": "ok", "windows": [{"percent": 42}]},
                {"id": "openai", "status": "error", "error": "Token expired"},
            ],
        }

    def usage(self, *flags, code=200):
        args = meterkat.build_parser().parse_args(["usage", "--port", "47301", *flags])
        output = io.StringIO()
        error = io.StringIO()
        with mock.patch.object(meterkat, "local_get", return_value=(code, self.snapshot)) as get:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                result = meterkat.cmd_usage(args, {"port": 47300, "token": "test-token"})
        return result, output.getvalue(), error.getvalue(), get

    def test_unfiltered_usage_keeps_the_full_snapshot(self):
        result, output, error, _ = self.usage()
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output), self.snapshot)
        self.assertEqual(error, "")

    def test_provider_filter_preserves_metadata_and_original_snapshot(self):
        result, output, error, _ = self.usage("--provider", "claude")
        expected = dict(self.snapshot, providers=[self.snapshot["providers"][0]])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output), expected)
        self.assertEqual(len(self.snapshot["providers"]), 2)
        self.assertEqual(error, "")

    def test_codex_provider_keeps_error_status(self):
        result, output, _, _ = self.usage("--provider", "openai")
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output)["providers"], [self.snapshot["providers"][1]])

    def test_absent_provider_returns_an_empty_array(self):
        result, output, _, _ = self.usage("--provider", "cursor")
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output)["providers"], [])

    def test_provider_filter_combines_with_refresh(self):
        result, output, _, get = self.usage("--provider", "claude", "--refresh")
        self.assertEqual(result, 0)
        self.assertEqual(len(json.loads(output)["providers"]), 1)
        get.assert_called_once_with(47301, "/v1/usage?refresh=1", "test-token",
                                    timeout=meterkat.HTTP_TIMEOUT + 5)

    def test_history_returns_rate_projections(self):
        history = {"generatedAt": "2026-10-13T00:00:00Z",
                   "series": [{"provider": "claude", "window": "five_hour",
                               "prediction": {"ratePerHour": 12.5}}]}
        args = meterkat.build_parser().parse_args(
            ["history", "--port", "47301", "--provider", "claude", "--window", "five_hour"])
        output = io.StringIO()
        with mock.patch.object(meterkat, "local_get", return_value=(200, history)) as get:
            with contextlib.redirect_stdout(output):
                result = meterkat.cmd_history(args, {"port": 47300, "token": "test-token"})
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue()), history)
        get.assert_called_once_with(47301, "/v1/history?provider=claude&window=five_hour",
                                    "test-token", timeout=meterkat.HTTP_TIMEOUT + 5)

    def test_unknown_provider_is_rejected_before_reading_config(self):
        with mock.patch.object(meterkat, "load_config") as load:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                meterkat.main(["usage", "--provider", "unknown"])
        self.assertEqual(error.exception.code, 2)
        load.assert_not_called()

    def test_service_errors_keep_stdout_empty(self):
        for code in (401, 503):
            with self.subTest(code=code):
                result, output, error, _ = self.usage("--provider", "claude", code=code)
                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertIn("meterkat:", error)


class OpenAIWindowTests(unittest.TestCase):
    HOUR, DAY = 3600, 86400
    RESET_EPOCH = 4102444800
    RESET_ISO = "2100-01-01T00:00:00Z"

    def setUp(self):
        logged = mock.patch.object(meterkat, "log")
        self.log = logged.start()
        self.addCleanup(logged.stop)
        shapes = mock.patch.object(meterkat, "_shapes_logged", set())
        shapes.start()
        self.addCleanup(shapes.stop)

    def win(self, secs=None, pct=10.0):
        win = {"used_percent": pct, "reset_at": self.RESET_EPOCH}
        if secs is not None:
            win["limit_window_seconds"] = secs
        return win

    def parse(self, primary=None, secondary=None, **top):
        rate = {}
        if primary is not None:
            rate["primary_window"] = primary
        if secondary is not None:
            rate["secondary_window"] = secondary
        return meterkat.parse_openai_windows(dict({"rate_limit": rate}, **top))

    def shape(self, window):
        return window["id"], window["kind"], window["label"], window["windowSeconds"]

    def test_todays_plus_response_is_unchanged(self):
        windows = self.parse(self.win(18000, 12.5), self.win(604800, 40.0))
        self.assertEqual(json.dumps(windows), json.dumps([
            {"id": "five_hour", "kind": "session", "label": "5-hour", "percent": 12.5,
             "resetsAt": self.RESET_ISO, "windowSeconds": 18000},
            {"id": "weekly", "kind": "weekly", "label": "Weekly", "percent": 40.0,
             "resetsAt": self.RESET_ISO, "windowSeconds": 604800},
        ]))
        self.log.assert_not_called()

    def test_todays_per_model_windows_are_unchanged(self):
        extra = [{"limit_name": "Fake Model-1", "rate_limit": {"primary_window": self.win(18000),
                                                                "secondary_window": self.win(604800)}}]
        windows = self.parse(additional_rate_limits=extra)
        self.assertEqual([self.shape(w) for w in windows], [
            ("five_hour_fake_model_1", "model", "Fake Model-1", 18000),
            ("weekly_fake_model_1", "model", "Fake Model-1", 604800),
        ])
        self.log.assert_not_called()

    def test_one_day_primary_is_daily(self):
        self.assertEqual([self.shape(w) for w in self.parse(self.win(self.DAY))],
                         [("daily", "daily", "Daily", self.DAY)])
        self.log.assert_not_called()

    def test_thirty_day_secondary_is_monthly(self):
        self.assertEqual([self.shape(w) for w in self.parse(secondary=self.win(30 * self.DAY))],
                         [("monthly", "monthly", "Monthly", 30 * self.DAY)])
        self.log.assert_not_called()

    def test_one_day_and_thirty_day_both_appear(self):
        windows = self.parse(self.win(self.DAY, 5.0), self.win(30 * self.DAY, 6.0))
        self.assertEqual([(w["id"], w["percent"]) for w in windows], [("daily", 5.0), ("monthly", 6.0)])

    def test_band_edges(self):
        hour, day = self.HOUR, self.DAY
        for secs, wid in ((1, "five_hour"), (6 * hour, "five_hour"), (6 * hour + 1, "window_21601"),
                          (20 * hour - 1, "window_71999"), (20 * hour, "daily"), (30 * hour, "daily"),
                          (30 * hour + 1, "window_108001"), (6 * day - 1, "window_518399"), (6 * day, "weekly"),
                          (8 * day, "weekly"), (8 * day + 1, "window_691201"), (28 * day - 1, "window_2419199"),
                          (28 * day, "monthly"), (31 * day, "monthly"), (31 * day + 1, "window_2678401")):
            with self.subTest(secs=secs):
                for slot_key in ("primary_window", "secondary_window"):
                    windows = meterkat.parse_openai_windows({"rate_limit": {slot_key: self.win(secs)}})
                    self.assertEqual(windows[0]["id"], wid)

    def test_odd_length_gets_a_label_and_id_from_its_length(self):
        for secs, label in ((3 * self.DAY, "3-day"), (12 * self.HOUR, "12-hour"), (14 * self.DAY, "14-day"),
                            (90 * self.DAY, "90-day"), (int(2.5 * self.DAY), "2.5-day"), (31 * self.HOUR, "31-hour")):
            with self.subTest(secs=secs):
                for key in ("primary", "secondary"):
                    windows = self.parse(**{key: self.win(secs)})
                    self.assertEqual([self.shape(w) for w in windows],
                                     [("window_%d" % secs, "session", label, secs)])

    def test_odd_length_is_logged_once_without_values(self):
        data = {"email": "fake@example.invalid", "rate_limit": {"primary_window": self.win(3 * self.DAY, 77.7)}}
        meterkat.parse_openai_windows(data)
        meterkat.parse_openai_windows(data)
        self.assertEqual(self.log.call_count, 1)
        line = self.log.call_args[0][0]
        self.assertIn("window length", line)
        self.assertIn("rate_limit", line)
        for value in ("fake@example.invalid", "259200", "77.7"):
            self.assertNotIn(value, line)

    def test_missing_length_uses_the_slot_default(self):
        windows = self.parse(self.win(), self.win())
        self.assertEqual([self.shape(w) for w in windows], [
            ("five_hour", "session", "5-hour", 18000), ("weekly", "weekly", "Weekly", 604800)])
        self.log.assert_not_called()

    def test_unusable_lengths_count_as_missing(self):
        for secs in (0, -5, "soon", True, float("inf"), float("nan")):
            with self.subTest(secs=secs):
                self.assertEqual(self.shape(self.parse(self.win(secs))[0]), ("five_hour", "session", "5-hour", 18000))

    def test_two_lengths_in_one_band_both_appear(self):
        windows = self.parse(self.win(18000), self.win(self.HOUR))
        self.assertEqual([self.shape(w) for w in windows], [
            ("five_hour", "session", "5-hour", 18000), ("window_3600", "session", "1-hour", self.HOUR)])
        windows = self.parse(self.win(7 * self.DAY), self.win(8 * self.DAY))
        self.assertEqual([self.shape(w) for w in windows], [
            ("weekly", "weekly", "Weekly", 7 * self.DAY), ("window_691200", "weekly", "8-day", 8 * self.DAY)])
        self.assertEqual(self.log.call_count, 1)

    def test_same_length_twice_keeps_one_window(self):
        for secs in (18000, 3 * self.DAY):
            with self.subTest(secs=secs):
                self.assertEqual(len(self.parse(self.win(secs, 1.0), self.win(secs, 2.0))), 1)

    def test_per_model_windows_follow_their_length(self):
        extra = {"fake": {"display_name": "Fake", "primary_window": self.win(self.DAY),
                          "secondary_window": self.win(30 * self.DAY)},
                 "odd": {"display_name": "Odd", "primary_window": self.win(3 * self.DAY),
                         "secondary_window": self.win(4 * self.DAY)},
                 "twice": {"display_name": "Twice", "primary_window": self.win(18000),
                           "secondary_window": self.win(self.HOUR)},
                 "bare": {"display_name": "Bare", "primary_window": self.win()}}
        windows = self.parse(self.win(18000), self.win(604800), additional_rate_limits=extra)
        self.assertEqual([self.shape(w) for w in windows[2:]], [
            ("daily_fake", "model", "Fake", self.DAY),
            ("monthly_fake", "model", "Fake", 30 * self.DAY),
            ("window_259200_odd", "model", "Odd 3-day", 3 * self.DAY),
            ("window_345600_odd", "model", "Odd 4-day", 4 * self.DAY),
            ("five_hour_twice", "model", "Twice", 18000),
            ("window_3600_twice", "model", "Twice 1-hour", self.HOUR),
            ("five_hour_bare", "model", "Bare", 18000),
        ])
        self.assertEqual(self.log.call_count, 1)

    def test_new_allowance_objects_are_logged_once_without_values(self):
        cases = {
            "unread window": ({"tertiary_window": {"used_percent": 77.7}}, {}, "tertiary_window"),
            "length only": ({"pool": {"limit_window_seconds": 2592000}}, {}, "pool"),
            "allowance key": ({"Shared_Allowance": {"remaining": 424242}}, {}, "Shared_Allowance"),
            "token key": ({"token_pool": {"remaining": 424242}}, {}, "token_pool"),
            "inside rate_limit": ({}, {"tertiary_window": {"used_percent": 77.7}}, "rate_limit.tertiary_window"),
        }
        for name, (top, rate, expected) in cases.items():
            with self.subTest(name), mock.patch.object(meterkat, "_shapes_logged", set()):
                self.log.reset_mock()
                data = dict({"email": "fake@example.invalid", "rate_limit": dict({"primary_window": self.win(18000)}, **rate)}, **top)
                windows = meterkat.parse_openai_windows(data)
                meterkat.parse_openai_windows(data)
                self.assertEqual([w["id"] for w in windows], ["five_hour"])
                self.assertEqual(self.log.call_count, 1)
                line = self.log.call_args[0][0]
                self.assertIn(expected, line)
                self.assertIn("email", line)
                for value in ("fake@example.invalid", "77.7", "2592000", "424242"):
                    self.assertNotIn(value, line)

    def test_known_keys_raise_no_alarm(self):
        window = {"used_percent": 1.0, "limit_window_seconds": 3600}
        self.parse(self.win(18000), self.win(604800),
                   credits={"balance": "0", "has_credits": False},
                   code_review_rate_limit=dict(window),
                   rate_limit_reset_credits={"available_count": 0},
                   spend_control=dict(window),
                   model_usage=dict(window),
                   additional_rate_limits=[],
                   promo={"message": "fake"},
                   token_count=5,
                   allowance_note="fake")
        self.log.assert_not_called()

    def test_window_and_allowance_traces_do_not_hide_each_other(self):
        self.parse(self.win(3 * self.DAY), token_pool={"remaining": 1})
        lines = [call[0][0] for call in self.log.call_args_list]
        self.assertEqual(len(lines), 2)
        self.assertIn("window length", lines[1])
        self.assertIn("token_pool", lines[0])

    def test_other_providers_still_log_once_per_provider(self):
        meterkat.log_shape_once("fake", "first", {})
        meterkat.log_shape_once("fake", "second", {})
        self.assertEqual(self.log.call_count, 1)

    def test_code_review_details_ignore_window_length(self):
        details = meterkat.parse_openai_details({"code_review_rate_limit": {"primary_window": self.win(3 * self.DAY, 20.0)}})
        self.assertEqual(details[0][0], "Code review")
        self.assertIn("20% used", details[0][1])
        self.log.assert_not_called()

    def snapshot(self, windows):
        return {"generatedAt": "2026-11-05T00:00:00Z", "providers": [
            {"id": "openai", "status": "ok", "stale": False, "fetchedAt": "2026-11-05T00:00:00Z", "windows": windows}]}

    def test_watch_thresholds_apply_to_new_windows(self):
        thresholds = meterkat.parse_thresholds([])
        low = self.parse(self.win(self.DAY, 90.0), self.win(30 * self.DAY, 90.0))
        key, events = meterkat.watch_check(self.snapshot(low), "openai", thresholds, now=0)
        self.assertEqual(events[0]["event"], "OK")
        self.assertEqual(events[0]["message"], "OK openai: Daily 90%, Monthly 90%")
        self.assertIn("daily:9", key)
        high = self.parse(self.win(self.DAY, 96.0), self.win(3 * self.DAY, 86.0))
        key, events = meterkat.watch_check(self.snapshot(high), "openai", thresholds, now=0)
        self.assertEqual(key, "limit")
        self.assertEqual([(e["kind"], e["windowId"], e["label"], e["threshold"]) for e in events], [
            ("daily", "daily", "Daily", 95.0), ("session", "window_259200", "3-day", 85.0)])
        only_monthly = meterkat.parse_thresholds(["monthly=50"])
        monthly = self.parse(secondary=self.win(30 * self.DAY, 60.0))
        self.assertEqual(meterkat.watch_check(self.snapshot(monthly), "openai", only_monthly, now=0)[0], "limit")

    def test_history_and_prediction_tolerate_new_windows(self):
        windows = self.parse(self.win(self.DAY, 10.0), self.win(30 * self.DAY, 20.0))
        windows += self.parse(self.win(3 * self.DAY, 30.0))
        snapshot = self.snapshot(windows)
        with tempfile.TemporaryDirectory() as folder:
            history = meterkat.History(os.path.join(folder, "history.json"))
            history.record(snapshot)
            payload = meterkat.history_payload(history, snapshot, provider="openai")
        self.assertEqual([s["window"] for s in payload["series"]], ["daily", "monthly", "window_259200"])
        now = self.RESET_EPOCH - 3600
        for window in windows:
            with self.subTest(window=window["id"]):
                prediction = meterkat.usage_prediction(window, [], now)
                self.assertEqual(prediction["basis"], "window_average")
                self.assertGreater(prediction["ratePerHour"], 0)


class CopilotTests(unittest.TestCase):
    """Fake values only. Shapes follow the live endpoint (2026-11); `max` and metered seats are unproven live."""

    def quota(self, entitlement, remaining, pct_left, used=None, token=True, unlimited=False):
        q = {"entitlement": entitlement, "remaining": remaining, "quota_remaining": float(remaining),
             "percent_remaining": pct_left, "unlimited": unlimited, "overage_count": 0}
        if token:
            q.update({"token_based_billing": True, "credits_used": used})
        return q

    def data(self, premium, token=True, plan="individual", sku="free_educational_quota"):
        return {"login": "fake", "copilot_plan": plan, "access_type_sku": sku, "token_based_billing": token,
                "quota_reset_date_utc": "2026-12-01T00:00:00.000Z",
                "quota_snapshots": {"premium_interactions": premium,
                                    "chat": {"unlimited": True, "entitlement": 0, "remaining": 0}}}

    def fetch(self, data):
        with mock.patch.object(meterkat, "read_github_token", return_value="fake"), \
                mock.patch.object(meterkat, "http_get_json", return_value=data):
            return meterkat.fetch_copilot()

    def test_legacy_premium_requests(self):
        data = self.data(self.quota(300, 100, 33.3, token=False), token=False, plan="pro", sku="copilot_pro_subscriber")
        res = self.fetch(data)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["plan"], "pro")
        win = res["windows"][0]
        self.assertEqual((win["id"], win["kind"], win["label"]), ("monthly", "monthly", "Premium requests"))
        self.assertEqual(win["percent"], 66.7)
        self.assertEqual(res["details"], [{"label": "Premium requests", "value": "200 of 300 used"}])

    def test_ai_credits(self):
        data = self.data(self.quota(200, 44, 22.3, used=155))
        res = self.fetch(data)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["plan"], "education")
        win = res["windows"][0]
        self.assertEqual((win["id"], win["kind"], win["label"]), ("monthly", "monthly", "AI Credits"))
        self.assertEqual(win["percent"], 77.7)
        self.assertEqual(res["details"], [{"label": "AI Credits", "value": "155 of 200 used ($1.55 of $2.00)"}])

    def test_ai_credits_without_credits_used_falls_back_to_remaining(self):
        res = self.fetch(self.data(self.quota(1000, 400, 40.0, used=None)))
        self.assertEqual(res["details"][0]["value"], "600 of 1000 used ($6.00 of $10.00)")

    def test_max_plan(self):
        self.assertEqual(meterkat.copilot_plan({"copilot_plan": "max"}), "max")
        self.assertEqual(meterkat.copilot_plan({"copilot_plan": "individual_max", "access_type_sku": "x"}), "max")
        self.assertEqual(meterkat.copilot_plan({"copilot_plan": "individual_pro"}), "individual_pro")
        res = self.fetch(self.data(self.quota(20000, 5000, 25.0, used=15000), plan="max", sku="plus_monthly_subscriber"))
        self.assertEqual(res["plan"], "max")
        self.assertEqual(res["details"][0]["value"], "15000 of 20000 used ($150.00 of $200.00)")

    def test_metered_seat_has_no_plan(self):
        data = self.data({"entitlement": 0, "remaining": 0, "percent_remaining": 100.0, "unlimited": False,
                          "token_based_billing": True, "credits_used": 12}, plan="enterprise", sku="enterprise")
        res = self.fetch(data)
        self.assertEqual(res["status"], "no_plan")
        self.assertEqual(res["windows"], [])
        self.assertIn("enterprise budget", res["error"])

    def test_unlimited_premium_is_not_metered(self):
        data = self.data(self.quota(0, 0, 100.0, used=0, unlimited=True))
        self.assertFalse(meterkat.copilot_metered_seat(data))


if __name__ == "__main__":
    unittest.main()
