import http.client
import time
import unittest
from unittest import mock

import meterkat


class ExpiredTokenTests(unittest.TestCase):
    def setUp(self):
        self.poller = meterkat.Poller()
        self.window = meterkat.make_window("weekly", "weekly", "Weekly", 40.0, "2026-10-04T00:00:00Z", meterkat.ONE_WEEK)
        self.good = meterkat.provider_result("claude", "Claude", plan="max", account="a@b.c", windows=[self.window])

    def fetch(self, result):
        return self.poller._fetch_one("claude", "Claude", lambda: result)

    def expired(self):
        return meterkat.provider_result("claude", "Claude", status="error", plan="max",
                                       error=meterkat.CLAUDE_EXPIRED)

    def test_expired_token_serves_last_good_marked_stale(self):
        self.fetch(self.good)
        result = self.fetch(self.expired())
        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["stale"])
        self.assertEqual(result["error"], meterkat.CLAUDE_EXPIRED)
        self.assertEqual(result["windows"], [self.window])
        self.assertEqual(result["fetchedAt"], self.good["fetchedAt"])
        self.assertNotIn("stale", self.good)

    def test_expired_token_without_last_good_is_an_error(self):
        self.assertEqual(self.fetch(self.expired())["status"], "error")

    def test_other_errors_are_not_masked(self):
        self.fetch(self.good)
        failed = meterkat.provider_result("claude", "Claude", status="error", error="Something else")
        self.assertEqual(self.fetch(failed)["status"], "error")

    def test_last_good_too_old_is_not_served(self):
        self.fetch(self.good)
        t, result = self.poller.last_good["claude"]
        self.poller.last_good["claude"] = (t - meterkat.EXPIRED_LAST_GOOD_MAX_AGE - 1, result)
        self.assertEqual(self.fetch(self.expired())["status"], "error")

    def test_fresh_data_clears_stale(self):
        self.fetch(self.good)
        self.fetch(self.expired())
        self.assertNotIn("stale", self.fetch(dict(self.good)))


class NetworkErrorTests(unittest.TestCase):
    def test_dropped_connection_is_transient(self):
        for error in (http.client.RemoteDisconnected("Remote end closed connection without response"),
                      http.client.IncompleteRead(b""), ConnectionResetError()):
            with mock.patch("urllib.request.urlopen", side_effect=error):
                with self.assertRaises(meterkat.ProviderError) as caught:
                    meterkat.http_get_json("https://example.com", {}, "expired")
            self.assertTrue(caught.exception.transient)
            self.assertTrue(str(caught.exception).startswith("Network error: "))

    def test_dropped_connection_serves_last_good(self):
        poller = meterkat.Poller()
        window = meterkat.make_window("five_hour", "session", "5-hour", 40.0, "2026-10-04T00:00:00Z", meterkat.FIVE_HOURS)
        good = meterkat.provider_result("claude", "Claude", windows=[window])
        poller._fetch_one("claude", "Claude", lambda: good)

        def dropped():
            with mock.patch("urllib.request.urlopen", side_effect=http.client.RemoteDisconnected("closed")):
                return meterkat.http_get_json("https://example.com", {}, "expired")

        with mock.patch.object(meterkat, "log"):
            self.assertEqual(poller._fetch_one("claude", "Claude", dropped), good)


class ResetCatchUpTests(unittest.TestCase):
    def snapshot(self, resets_at, status="ok", stale=False):
        window = meterkat.make_window("five_hour", "session", "5-hour", 40.0,
                                      meterkat.normalize_time(resets_at), meterkat.FIVE_HOURS)
        provider = meterkat.provider_result("claude", "Claude", status=status, windows=[window])
        provider["stale"] = stale
        return {"providers": [provider]}

    def test_reset_pending_only_just_after_a_reset(self):
        now = time.time()
        self.assertTrue(meterkat.reset_pending(self.snapshot(now - 10), now))
        self.assertFalse(meterkat.reset_pending(self.snapshot(now + 10), now))
        self.assertFalse(meterkat.reset_pending(self.snapshot(now - meterkat.RESET_CATCHUP_SECONDS - 10), now))
        self.assertFalse(meterkat.reset_pending(self.snapshot(now - 10, stale=True), now))
        self.assertFalse(meterkat.reset_pending(self.snapshot(now - 10, status="error"), now))
        self.assertFalse(meterkat.reset_pending(None, now))

    def test_next_reset(self):
        now = time.time()
        self.assertEqual(meterkat.next_reset(self.snapshot(now + 60), now), int(now + 60))
        self.assertIsNone(meterkat.next_reset(self.snapshot(now - 60), now))

    def poller_with(self, snapshot, age):
        poller = meterkat.Poller()
        poller.snapshot = snapshot
        poller.snapshot_time = time.monotonic() - age
        return poller

    def test_poll_wakes_just_after_an_upcoming_reset(self):
        poller = self.poller_with(self.snapshot(time.time() + 40), age=0)
        self.assertAlmostEqual(poller._poll_delay(120), 42, delta=1)
        far = self.poller_with(self.snapshot(time.time() + 3600), age=0)
        self.assertEqual(far._poll_delay(120), 120)

    def test_poll_retries_while_a_reset_is_pending(self):
        poller = self.poller_with(self.snapshot(time.time() - 5), age=0)
        self.assertEqual(poller._poll_delay(120), meterkat.RESET_RETRY_SECONDS)

    def test_get_refreshes_early_after_a_reset(self):
        poller = self.poller_with(self.snapshot(time.time() - 5), age=meterkat.RESET_RETRY_SECONDS + 1)
        with mock.patch.object(poller, "refresh_in_background") as refresh:
            poller.get()
        refresh.assert_called_once_with(meterkat.RESET_RETRY_SECONDS)

    def test_get_keeps_the_cache_without_a_reset(self):
        poller = self.poller_with(self.snapshot(time.time() + 600), age=meterkat.RESET_RETRY_SECONDS + 1)
        with mock.patch.object(poller, "refresh_in_background") as refresh:
            poller.get()
        refresh.assert_not_called()


if __name__ == "__main__":
    unittest.main()
