import json
import os
import sqlite3
import tempfile
import time
import unittest
from unittest import mock

import meterkat

NOW_MS = int(time.time() * 1000)
ASSISTANT = {"role": "assistant", "providerID": "opencode-go", "cost": 0.5,
             "tokens": {"input": 100, "output": 50, "reasoning": 0, "cache": {"read": 10, "write": 0}}}


class OpenCodeKeyTests(unittest.TestCase):
    def key(self, auth, *names):
        with tempfile.TemporaryDirectory() as folder:
            os.makedirs(os.path.join(folder, "opencode"))
            with open(os.path.join(folder, "opencode", "auth.json"), "w") as f:
                json.dump(auth, f)
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": folder}):
                return meterkat.opencode_saved_key(*names)

    def test_old_shape(self):
        self.assertEqual(self.key({"opencode-go": {"type": "api", "key": "fake-old"}}, "opencode-go"), "fake-old")

    def test_metadata_shape(self):
        auth = {"opencode-go": {"type": "api", "metadata": {"key": "fake-new"}}}
        self.assertEqual(self.key(auth, "opencode-go"), "fake-new")
        self.assertEqual(self.key({"opencode-go": {"metadata": {"key": "fake-new"}}}, "opencode-go"), "fake-new")

    def test_skips_other_types_and_empty(self):
        auth = {"a": {"type": "oauth", "access": "fake"}, "b": {"type": "api", "metadata": {}},
                "c": {"type": "api", "key": "fake-c"}}
        self.assertEqual(self.key(auth, "a", "b", "c"), "fake-c")
        self.assertIsNone(self.key(auth, "a", "b"))


class OpenCodeLocalUsageTests(unittest.TestCase):
    def details(self, v1=(), v2=(), v2_table=True):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "opencode.db")
            conn = sqlite3.connect(path)
            conn.execute("CREATE TABLE message (id text, session_id text, time_created integer, data text)")
            if v2_table:
                conn.execute("CREATE TABLE session_message (id text, session_id text, type text, seq integer,"
                             " time_created integer, data text)")
            for mid, data in v1:
                conn.execute("INSERT INTO message VALUES (?, 's', ?, ?)", (mid, NOW_MS - 1000, json.dumps(data)))
            for mid, kind, data in v2:
                conn.execute("INSERT INTO session_message VALUES (?, 's', ?, 0, ?, ?)",
                             (mid, kind, NOW_MS - 1000, json.dumps(data)))
            conn.commit()
            conn.close()
            with mock.patch.object(meterkat, "short_hostname", return_value="host"):
                return dict(meterkat._opencode_usage_details(path))

    def v2_data(self, provider="opencode-go", cost=1.0):
        return {"model": {"id": "m", "providerID": provider}, "cost": cost,
                "tokens": {"input": 1000, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}}

    def test_v1_only(self):
        details = self.details(v1=[("m1", ASSISTANT)], v2_table=False)
        self.assertEqual(details["Go on host · 7 days"], "$0.50 · 160 tokens")

    def test_v2_table_counted(self):
        details = self.details(v2=[("n1", "assistant", self.v2_data())])
        self.assertEqual(details["Go on host · 7 days"], "$1.00 · 1.0k tokens")

    def test_message_in_both_tables_counted_once(self):
        v2 = dict(self.v2_data(cost=0.5), tokens=ASSISTANT["tokens"])
        details = self.details(v1=[("m1", ASSISTANT)], v2=[("m1", "assistant", v2),
                                                          ("n2", "user", {"text": "hi"}),
                                                          ("n3", "assistant", self.v2_data(cost=2.0))])
        self.assertEqual(details["Go on host · 30 days"], "$2.50 · 1.2k tokens")


class OpenCodeWindowTests(unittest.TestCase):
    RESET = "2030-01-01T05:00:00Z"

    def win(self, percent):
        return {"percent": percent, "resetsAt": self.RESET}

    def by_id(self, windows):
        return {w["id"]: w for w in windows}

    def test_old_single_window_shape(self):
        data = {"usage": {"rolling": self.win(10), "weekly": self.win(20), "monthly": self.win(30)}}
        windows = meterkat.parse_opencode_windows(data)
        self.assertEqual([(w["id"], w["kind"], w["percent"]) for w in windows],
                         [("five_hour", "session", 10.0), ("weekly", "weekly", 20.0), ("monthly", "monthly", 30.0)])
        self.assertEqual(meterkat.parse_opencode_plan(data), "go")

    def test_per_model_dict(self):
        data = {"plan": "Go Plus", "usage": {"models": {
            "GLM-5.3": {"rolling": self.win(40), "weekly": self.win(10), "monthly": self.win(5)},
            "Kimi K3": {"rolling": self.win(70), "weekly": self.win(30)}}}}
        windows = meterkat.parse_opencode_windows(data)
        by = self.by_id(windows)
        self.assertEqual(by["five_hour"]["kind"], "session")
        self.assertEqual(by["five_hour"]["percent"], 70.0)
        self.assertEqual(by["weekly"]["percent"], 30.0)
        self.assertEqual(by["monthly"]["percent"], 5.0)
        self.assertEqual(by["five_hour_glm_5_3"]["kind"], "model")
        self.assertEqual(by["five_hour_glm_5_3"]["label"], "GLM-5.3 5-hour")
        self.assertEqual(by["weekly_kimi_k3"]["percent"], 30.0)
        self.assertNotIn("monthly_kimi_k3", by)
        self.assertEqual([w["id"] for w in windows][:3], ["five_hour", "weekly", "monthly"])
        self.assertEqual(meterkat.parse_opencode_plan(data), "go plus")

    def test_per_model_list_with_dollars(self):
        data = {"usage": {"models": [
            {"model": "GLM-5.3", "windows": [
                {"window": "rolling", "usageDollars": 3.0, "limitDollars": 6.0, "resetInSec": 3600},
                {"window": "weekly", "percent": 12}]},
            {"model": "Kimi K3", "rolling": self.win(20)}]}}
        by = self.by_id(meterkat.parse_opencode_windows(data))
        self.assertEqual(by["five_hour"]["percent"], 50.0)
        self.assertEqual(by["five_hour_kimi_k3"]["percent"], 20.0)
        self.assertEqual(by["weekly_glm_5_3"]["percent"], 12.0)

    def test_own_headline_kept(self):
        data = {"usage": {"rolling": self.win(5), "models": {"A": {"rolling": self.win(90)}}}}
        by = self.by_id(meterkat.parse_opencode_windows(data))
        self.assertEqual(by["five_hour"]["percent"], 5.0)
        self.assertEqual(by["five_hour_a"]["percent"], 90.0)

    def test_plan_names(self):
        for given, expected in (("Go Teams", "go teams"), ({"name": "go-plus"}, "go plus"), ("Go", "go"),
                                ("mystery", "go")):
            self.assertEqual(meterkat.parse_opencode_plan({"usage": {"plan": given}}), expected)

    def test_unrecognised(self):
        self.assertEqual(meterkat.parse_opencode_windows({"foo": 1}), [])


if __name__ == "__main__":
    unittest.main()
