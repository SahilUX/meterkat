import contextlib
import io
import json
import threading
import time
import unittest
from unittest import mock

import meterkat

FUTURE = "2099-01-01T00:00:00Z"
PAST = "2000-01-01T00:00:00Z"


def snapshot(generated, windows, status="ok", stale=False, provider="claude"):
    return {
        "generatedAt": generated,
        "providers": [{"id": provider, "status": status, "stale": stale, "error": None, "windows": windows}],
    }


def window(wid, kind, percent, resets=FUTURE, label=None):
    return {"id": wid, "kind": kind, "label": label or wid, "percent": percent, "resetsAt": resets}


class ThresholdTests(unittest.TestCase):
    def test_defaults(self):
        t = meterkat.parse_thresholds(None)
        self.assertEqual(meterkat.threshold_for(t, "session"), 85)
        self.assertEqual(meterkat.threshold_for(t, "weekly"), 95)
        self.assertEqual(meterkat.threshold_for(t, "model"), 95)

    def test_bare_value_sets_every_kind(self):
        t = meterkat.parse_thresholds(["50"])
        for kind in meterkat.WINDOW_KINDS:
            self.assertEqual(meterkat.threshold_for(t, kind), 50)

    def test_per_kind_overrides_and_off(self):
        t = meterkat.parse_thresholds(["80", "session=60", "model=off"])
        self.assertEqual(meterkat.threshold_for(t, "session"), 60)
        self.assertEqual(meterkat.threshold_for(t, "weekly"), 80)
        self.assertIsNone(meterkat.threshold_for(t, "model"))

    def test_rejects_bad_values(self):
        for spec in ("five_hour=80", "session=abc", "session=0", "120"):
            with self.assertRaises(ValueError):
                meterkat.parse_thresholds([spec])


class CheckTests(unittest.TestCase):
    def check(self, snap, *specs):
        return meterkat.watch_check(snap, "claude", meterkat.parse_thresholds(list(specs)))

    def test_below_threshold_is_ok(self):
        key, events = self.check(snapshot("t1", [window("five_hour", "session", 40)]))
        self.assertNotEqual(key, "limit")
        self.assertEqual(events[0]["event"], "OK")

    def test_limit_by_kind_not_label(self):
        snap = snapshot("t1", [window("five_hour", "session", 86, label="Renamed")])
        key, events = self.check(snap)
        self.assertEqual(key, "limit")
        self.assertEqual(events[0]["kind"], "session")
        self.assertEqual(events[0]["resetsAt"], FUTURE)
        self.assertIn("LIMIT claude session", events[0]["message"])

    def test_model_window_uses_its_own_threshold(self):
        snap = snapshot("t1", [window("weekly_fable", "model", 90)])
        self.assertNotEqual(self.check(snap)[0], "limit")
        self.assertEqual(self.check(snap, "model=90")[0], "limit")
        self.assertNotEqual(self.check(snap, "90", "model=off")[0], "limit")

    def test_expired_window_is_ignored(self):
        snap = snapshot("t1", [window("five_hour", "session", 99, resets=PAST)])
        self.assertNotEqual(self.check(snap)[0], "limit")

    def test_key_changes_only_on_ten_point_steps_and_staleness(self):
        a = self.check(snapshot("t1", [window("five_hour", "session", 41)]))[0]
        b = self.check(snapshot("t2", [window("five_hour", "session", 48)]))[0]
        c = self.check(snapshot("t3", [window("five_hour", "session", 51)]))[0]
        d = self.check(snapshot("t4", [window("five_hour", "session", 51)], stale=True))[0]
        self.assertEqual(a, b)
        self.assertNotEqual(b, c)
        self.assertNotEqual(c, d)

    def test_absent_and_error_status_warn(self):
        self.assertEqual(self.check({"providers": []})[1][0]["event"], "WARN")
        key, events = self.check(snapshot("t1", [], status="error"))
        self.assertEqual(key, "status-error")
        self.assertEqual(events[0]["event"], "WARN")


class CommandTests(unittest.TestCase):
    def run_watch(self, responses, *flags):
        args = meterkat.build_parser().parse_args(["watch", "--port", "47301", *flags])
        calls = []

        def fake_get(port, path, token=None, timeout=3):
            calls.append(path)
            if path == "/health":
                return 200, {"ok": True, "pollSeconds": 120}
            return responses.pop(0)

        out = io.StringIO()
        with mock.patch.object(meterkat, "local_get", side_effect=fake_get), \
                mock.patch.object(meterkat.time, "sleep") as sleep, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = meterkat.cmd_watch(args, {"port": 47300, "token": "t"})
        return code, out.getvalue().splitlines(), [c for c in calls if c != "/health"], sleep

    def test_once_ok_and_limit(self):
        code, lines, _, _ = self.run_watch([(200, snapshot("t1", [window("five_hour", "session", 40)]))], "--once")
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].startswith("OK claude"))
        code, lines, _, _ = self.run_watch([(200, snapshot("t1", [window("five_hour", "session", 40)]))],
                                           "--once", "--at", "30")
        self.assertEqual(code, 3)
        self.assertTrue(lines[0].startswith("LIMIT claude session"))

    def test_once_unavailable_exits_1(self):
        code, lines, _, _ = self.run_watch([(None, None)], "--once")
        self.assertEqual(code, 1)
        self.assertTrue(lines[0].startswith("ERROR"))

    def assert_once_no_reading(self, snap, *flags):
        code, lines, _, _ = self.run_watch([(200, snap)], "--once", *flags)
        self.assertEqual(code, meterkat.WATCH_NO_READING_EXIT)
        self.assertEqual(code, 4)
        self.assertEqual(len(lines), 1)
        return lines[0]

    def test_once_not_signed_in_exits_4(self):
        line = self.assert_once_no_reading(snapshot("t1", [], status="not_signed_in"))
        self.assertTrue(line.startswith("WARN claude status not_signed_in"))

    def test_once_error_status_exits_4(self):
        snap = snapshot("t1", [window("five_hour", "session", 40)], status="error")
        self.assertTrue(self.assert_once_no_reading(snap).startswith("WARN claude status error"))

    def test_once_absent_provider_exits_4(self):
        line = self.assert_once_no_reading(snapshot("t1", [window("a", "session", 40)], provider="openai"))
        self.assertTrue(line.startswith("WARN claude not tracked"))

    def test_once_stale_exits_4(self):
        line = self.assert_once_no_reading(snapshot("t1", [window("five_hour", "session", 40)], stale=True))
        self.assertEqual(line, "WARN no usable reading: claude STALE: five_hour 40%")

    def test_once_no_windows_exits_4(self):
        line = self.assert_once_no_reading(snapshot("t1", []))
        self.assertEqual(line, "WARN no usable reading: claude: no limits reported")

    def test_once_all_windows_expired_exits_4(self):
        snap = snapshot("t1", [window("five_hour", "session", 99, resets=PAST),
                               window("weekly", "weekly", 10, resets=PAST)])
        line = self.assert_once_no_reading(snap)
        self.assertEqual(line, "WARN no usable reading: claude: five_hour 99% (expired), weekly 10% (expired)")

    def test_once_no_reading_json_stays_valid(self):
        snap = snapshot("t1", [window("five_hour", "session", 40)], stale=True)
        event = json.loads(self.assert_once_no_reading(snap, "--json"))
        self.assertEqual((event["event"], event["stale"]), ("WARN", True))
        self.assertEqual(event["windows"][0]["percent"], 40.0)
        self.assertNotIn("message", event)
        event = json.loads(self.assert_once_no_reading(snapshot("t1", [], status="error"), "--json"))
        self.assertEqual((event["event"], event["status"]), ("WARN", "error"))

    def test_once_stale_at_threshold_is_still_limit(self):
        code, lines, _, _ = self.run_watch([(200, snapshot("t1", [window("five_hour", "session", 90)], stale=True))],
                                           "--once")
        self.assertEqual(code, 3)
        self.assertTrue(lines[0].startswith("LIMIT claude session"))

    def test_once_fresh_reading_exits_0(self):
        code, lines, _, _ = self.run_watch([(200, snapshot("t1", [window("five_hour", "session", 40)]))], "--once")
        self.assertEqual(code, 0)
        self.assertEqual(lines, ["OK claude: five_hour 40%"])

    def test_once_some_windows_live_exits_0(self):
        snaps = [
            snapshot("t1", [window("five_hour", "session", 99, resets=PAST), window("weekly", "weekly", 10)]),
            snapshot("t1", [window("credit", "credit", 10, resets=None)]),  # no reset time isn't expired
        ]
        for snap in snaps:
            self.assertEqual(self.run_watch([(200, snap)], "--once")[0], 0)

    def test_without_once_no_reading_keeps_waiting(self):
        responses = [
            (200, {"generatedAt": "t1", "providers": []}),
            (200, snapshot("t2", [], status="not_signed_in")),
            (200, snapshot("t3", [window("five_hour", "session", 40)], stale=True)),
            (200, snapshot("t4", [])),
            (200, snapshot("t5", [window("five_hour", "session", 99, resets=PAST)])),
            (200, snapshot("t6", [window("five_hour", "session", 90)])),
        ]
        code, lines, paths, _ = self.run_watch(responses)
        self.assertEqual(code, 3)
        self.assertEqual(len(paths), 6)
        self.assertEqual(lines[2:5], ["OK claude STALE: five_hour 40%", "OK claude: no limits reported",
                                      "OK claude: five_hour 99% (expired)"])
        self.assertTrue(lines[0].startswith("WARN claude not tracked"))
        self.assertTrue(lines[1].startswith("WARN claude status not_signed_in"))
        self.assertTrue(lines[5].startswith("LIMIT claude session"))

    def test_bad_threshold_exits_2(self):
        self.assertEqual(self.run_watch([], "--at", "bogus=1")[0], 2)

    def test_long_polls_and_prints_only_changes(self):
        responses = [
            (200, snapshot("t1", [window("five_hour", "session", 41)])),
            (200, snapshot("t2", [window("five_hour", "session", 45)])),
            (200, snapshot("t3", [window("five_hour", "session", 88)])),
        ]
        code, lines, paths, _ = self.run_watch(responses)
        self.assertEqual(code, 3)
        self.assertEqual(len(lines), 2)  # OK once, then LIMIT
        self.assertEqual(paths[0], "/v1/usage")
        self.assertIn("since=t1", paths[1])
        self.assertIn("since=t2", paths[2])
        self.assertTrue(all("refresh" not in p for p in paths))

    def test_json_events(self):
        code, lines, _, _ = self.run_watch([(200, snapshot("t1", [window("five_hour", "session", 90)]))], "--json")
        event = json.loads(lines[0])
        self.assertEqual(code, 3)
        self.assertEqual((event["event"], event["kind"], event["threshold"]), ("LIMIT", "session", 85))
        self.assertNotIn("message", event)

    def test_old_companion_without_long_poll_backs_off(self):
        same = (200, snapshot("t1", [window("five_hour", "session", 41)]))
        responses = [same, same, (200, snapshot("t2", [window("five_hour", "session", 90)]))]
        code, _, _, sleep = self.run_watch(responses)
        self.assertEqual(code, 3)
        sleep.assert_called_with(meterkat.WATCH_FALLBACK_SLEEP)


class WaitNewerTests(unittest.TestCase):
    def test_wakes_on_new_snapshot_and_times_out(self):
        poller = meterkat.Poller(cache_seconds=0)
        poller.snapshot, poller.snapshot_time = {"generatedAt": "t1"}, time.monotonic()
        started = time.monotonic()
        self.assertEqual(poller.wait_newer("t1", 0.05)["generatedAt"], "t1")
        self.assertGreaterEqual(time.monotonic() - started, 0.04)

        def publish():
            time.sleep(0.05)
            with poller.lock:
                poller.snapshot = {"generatedAt": "t2"}
                poller.updated.notify_all()

        threading.Thread(target=publish).start()
        self.assertEqual(poller.wait_newer("t1", 5)["generatedAt"], "t2")

    def test_returns_at_once_when_already_newer(self):
        poller = meterkat.Poller()
        poller.snapshot = {"generatedAt": "t2"}
        with mock.patch.object(poller, "build") as build:
            self.assertEqual(poller.wait_newer("t1", 5)["generatedAt"], "t2")
        build.assert_not_called()


class SnapshotShapeTests(unittest.TestCase):
    def test_percent_is_rounded(self):
        self.assertEqual(meterkat.make_window("m", "monthly", "M", 4.099999999999994, None, None)["percent"], 4.1)

    def test_unknown_kind_is_rejected(self):
        with self.assertRaises(AssertionError):
            meterkat.make_window("x", "fortnightly", "X", 1, None, None)

    def test_stale_is_always_present(self):
        poller = meterkat.Poller()
        poller.cost_cache_time = time.monotonic()
        good = meterkat.provider_result("claude", "Claude")
        with mock.patch.object(meterkat, "PROVIDERS", [("claude", "Claude", lambda: good)]), \
                mock.patch.object(meterkat, "disabled_providers", return_value=set()):
            snap = poller.build()
        self.assertIs(snap["providers"][0]["stale"], False)

    def test_build_does_not_wait_for_the_cost_scan(self):
        poller = meterkat.Poller()
        release = threading.Event()
        def slow_scan(**_):
            release.wait(10)
            return {"claude": {"weekUSD": 1.0}}
        good = meterkat.provider_result("claude", "Claude")
        with mock.patch.object(meterkat, "PROVIDERS", [("claude", "Claude", lambda: good)]), \
                mock.patch.object(meterkat, "disabled_providers", return_value=set()), \
                mock.patch.object(meterkat.api_cost, "estimates", side_effect=slow_scan):
            started = time.monotonic()
            poller.snapshot = poller.build()
            self.assertLess(time.monotonic() - started, 5)
            self.assertNotIn("apiCost", poller.snapshot["providers"][0])
            release.set()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and "apiCost" not in poller.snapshot["providers"][0]:
                time.sleep(0.01)
        self.assertEqual(poller.snapshot["providers"][0]["apiCost"], {"weekUSD": 1.0})


if __name__ == "__main__":
    unittest.main()
