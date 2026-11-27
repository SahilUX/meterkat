import contextlib
import io
import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest import mock

import devices
import discovery
import meterkat

SHARED = "shared-token-for-tests"
REMOTE = {"X-Forwarded-For": "10.0.0.5"}  # looks like a remote client behind a local proxy


class FakePoller:
    poll_seconds = 120
    history = None

    def __init__(self):
        self.cond = threading.Condition()
        self.snapshot = {"generatedAt": "t1", "host": "testbox", "companionVersion": meterkat.VERSION,
                         "providers": []}

    def get(self, force=False):
        return self.snapshot

    def wait_newer(self, since, timeout):
        deadline = time.monotonic() + timeout
        with self.cond:
            while self.snapshot["generatedAt"] == since:
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.cond.wait(left)
            return self.snapshot

    def publish(self, generated):
        with self.cond:
            self.snapshot = dict(self.snapshot, generatedAt=generated)
            self.cond.notify_all()


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "config.json")
        devices.write_config(self.path, {"token": SHARED, "port": 47300})
        self.store = devices.DeviceStore(self.path)


class StoreTests(StoreCase):
    def test_mint_stores_a_hash_never_the_token(self):
        token, record = self.store.mint("Home Assistant")
        self.assertTrue(token.startswith("mkd_%s_" % record["id"]))
        self.assertGreaterEqual(len(token.split("_", 2)[2]), 40)
        with open(self.path) as f:
            raw = f.read()
        self.assertNotIn(token, raw)
        self.assertNotIn(token.split("_", 2)[2], raw)
        self.assertIn(devices.hash_token(token), raw)
        self.assertEqual(oct(os.stat(self.path).st_mode & 0o777), "0o600")
        self.assertEqual(record["role"], "viewer")
        self.assertIsNone(record["lastUsedAt"])

    def test_authenticate(self):
        token, record = self.store.mint("Phone", "owner")
        self.assertEqual(self.store.authenticate(token)["id"], record["id"])
        for bad in (token + "x", "mkd_%s_wrong" % record["id"], "mkd_nope_x", "mkd_", SHARED, "", None):
            self.assertIsNone(self.store.authenticate(bad))

    def test_names_are_cleaned(self):
        _, record = self.store.mint("  Kitchen\x07 tablet  " + "x" * 100)
        self.assertEqual(len(record["name"]), devices.MAX_NAME)
        self.assertTrue(record["name"].startswith("Kitchen tablet"))
        _, record = self.store.mint("   ")
        self.assertEqual(record["name"], devices.DEFAULT_NAME)

    def test_revoke_by_id_prefix_and_name(self):
        _, a = self.store.mint("Alpha")
        token_b, b = self.store.mint("Beta")
        self.assertEqual(self.store.revoke(a["id"][:4], host=True)["id"], a["id"])
        self.assertEqual(self.store.revoke("beta", host=True)["id"], b["id"])
        self.assertIsNone(self.store.authenticate(token_b))
        with self.assertRaises(devices.DeviceError) as ctx:
            self.store.revoke("beta", host=True)
        self.assertEqual(ctx.exception.code, "not_found")

    def test_names_resolve_only_for_the_host(self):
        self.store.mint("Alpha")
        with self.assertRaises(devices.DeviceError):
            self.store.revoke("Alpha")

    def test_ambiguous_name(self):
        self.store.mint("Same")
        self.store.mint("Same")
        with self.assertRaises(devices.DeviceError) as ctx:
            self.store.revoke("same", host=True)
        self.assertEqual(ctx.exception.code, "ambiguous")

    def test_last_owner_is_protected_except_for_the_host(self):
        _, owner = self.store.mint("Mac", "owner")
        with self.assertRaises(devices.DeviceError) as ctx:
            self.store.revoke(owner["id"])
        self.assertEqual(ctx.exception.code, "last_owner")
        self.assertIn("meterkat devices revoke", ctx.exception.message)
        _, second = self.store.mint("Phone", "owner")
        self.store.revoke(owner["id"])  # fine while another owner remains
        self.store.revoke(second["id"], host=True)

    def test_a_second_process_sees_a_revoke_at_once(self):
        token, record = self.store.mint("Phone")
        self.assertTrue(self.store.authenticate(token))
        devices.DeviceStore(self.path).revoke(record["id"], host=True)  # the CLI, another process
        self.assertIsNone(self.store.authenticate(token))
        self.assertFalse(self.store.exists(record["id"]))

    def test_last_active_is_persisted_at_most_once_a_minute(self):
        token, record = self.store.mint("Phone")
        writes = []
        real = devices.write_config
        with mock.patch.object(devices, "write_config", lambda p, c: (writes.append(1), real(p, c))):
            self.store.touch(record["id"])  # the first one writes
            for _ in range(20):
                self.store.touch(record["id"])
            self.assertEqual(len(writes), 1)
            self.assertIsNotNone(devices.DeviceStore(self.path).records()[0]["lastUsedAt"])
            with mock.patch.object(time, "monotonic", return_value=time.monotonic() + 61), \
                    mock.patch.object(devices, "now_iso", return_value="2099-01-01T00:00:00Z"):
                self.store.touch(record["id"])
            self.assertEqual(len(writes), 2)

    def test_a_devices_first_request_is_written_at_once(self):
        _, first = self.store.mint("First")
        _, second = self.store.mint("Second")
        self.store.touch(first["id"])
        self.store.touch(second["id"])  # inside the minute, but it has never been used
        by_id = {r["id"]: r for r in devices.DeviceStore(self.path).records()}
        self.assertIsNotNone(by_id[second["id"]]["lastUsedAt"])

    def test_flush_writes_what_is_pending(self):
        _, record = self.store.mint("Phone")
        self.store.touch(record["id"])  # written
        self.store.touch("shared")      # its first request: written
        self.store.touch("shared")      # pending until a minute passes
        with mock.patch.object(devices, "now_iso", return_value="2099-01-01T00:00:00Z"):
            self.store.touch("shared")
        self.assertNotEqual(devices.DeviceStore(self.path).shared_last_used(), "2099-01-01T00:00:00Z")
        self.store.flush()
        self.assertEqual(devices.DeviceStore(self.path).shared_last_used(), "2099-01-01T00:00:00Z")

    def test_a_cli_save_does_not_undo_the_services_devices(self):
        token, record = self.store.mint("Phone")
        with mock.patch.object(meterkat, "CONFIG_PATH", self.path), mock.patch.object(meterkat, "CONFIG_DIR", self.dir.name):
            stale = {"token": SHARED, "port": 47300, "disabledProviders": ["cursor"]}  # loaded before the pairing
            meterkat.save_config(stale)
        with open(self.path) as f:
            saved = json.load(f)
        self.assertEqual([d["id"] for d in saved["devices"]], [record["id"]])
        self.assertEqual(saved["disabledProviders"], ["cursor"])

    def test_touch_ignores_unknown_ids(self):
        self.store.touch("nope")
        with open(self.path) as f:
            self.assertNotIn("devices", json.load(f))

    def test_relative_times(self):
        from datetime import datetime, timezone
        now = datetime(2026, 10, 25, 12, 0, 0, tzinfo=timezone.utc)
        self.assertEqual(devices.relative("2026-10-22T12:00:00Z", now), "3 days ago")
        self.assertEqual(devices.relative("2026-10-25T11:59:00Z", now), "1 minute ago")
        self.assertEqual(devices.relative("2026-10-25T11:59:50Z", now), "just now")
        self.assertEqual(devices.relative(None, now), "never")


class GuardTests(unittest.TestCase):
    def test_blocks_after_repeated_failures_then_lets_go(self):
        now = [0.0]
        guard = devices.AuthGuard(limit=3, window=60, block=120, clock=lambda: now[0])
        for _ in range(2):
            guard.fail("1.2.3.4")
        self.assertEqual(guard.retry_after("1.2.3.4"), 0)
        guard.fail("1.2.3.4")
        self.assertGreater(guard.retry_after("1.2.3.4"), 0)
        self.assertEqual(guard.retry_after("5.6.7.8"), 0)
        now[0] = 121
        self.assertEqual(guard.retry_after("1.2.3.4"), 0)

    def test_old_failures_age_out_and_success_resets(self):
        now = [0.0]
        guard = devices.AuthGuard(limit=3, window=60, block=120, clock=lambda: now[0])
        guard.fail("a")
        guard.fail("a")
        now[0] = 100
        guard.fail("a")
        self.assertEqual(guard.retry_after("a"), 0)
        guard.fail("b")
        guard.fail("b")
        guard.ok("b")
        guard.fail("b")
        self.assertEqual(guard.retry_after("b"), 0)


class ServerCase(StoreCase):
    def setUp(self):
        super().setUp()
        self.poller = FakePoller()
        self.cfg = {"token": SHARED, "port": 47300, "companionId": "abc123abc123"}
        self.codes = meterkat.PairingCodes()
        self.guard = devices.AuthGuard(limit=5)
        handler = meterkat.make_handler(self.poller, self.cfg, 47300, "127.0.0.1", self.codes, self.store, self.guard)
        patches = [mock.patch.object(meterkat, "CONFIG_PATH", self.path),
                   mock.patch.object(meterkat, "CONFIG_DIR", self.dir.name),
                   mock.patch.object(meterkat, "log", lambda *a, **k: None)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def call(self, method, path, token=None, body=None, headers=None, timeout=10):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        if token:
            req.add_header("Authorization", "Bearer " + token)
        for key, value in (headers or {}).items():
            req.add_header(key, value)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req, timeout=timeout) as resp:
                return resp.status, json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode() or "null")

    def pair(self, name, role="viewer", **kw):
        code = self.codes.issue(SHARED, role)
        status, body = self.call("POST", "/v1/pair", body=dict({"code": code, "name": name}, **kw))
        self.assertEqual(status, 200, body)
        return body


class PairingTests(ServerCase):
    def test_a_named_pairing_gets_its_own_token(self):
        body = self.pair("Home Assistant")
        self.assertTrue(body["token"].startswith("mkd_"))
        self.assertEqual((body["role"], body["name"]), ("viewer", "Home Assistant"))
        status, usage = self.call("GET", "/v1/usage", body["token"])
        self.assertEqual(status, 200)
        self.assertEqual(usage["companionId"], "abc123abc123")
        self.assertEqual(self.call("GET", "/v1/history", body["token"])[0], 200)
        self.assertEqual(self.call("GET", "/v1/me", body["token"])[1]["role"], "viewer")

    def test_a_pairing_without_a_name_still_gets_the_shared_token(self):
        code = self.codes.issue(SHARED)
        status, body = self.call("POST", "/v1/pair", body={"code": code})
        self.assertEqual((status, body), (200, {"token": SHARED}))

    def test_a_code_works_once(self):
        code = self.codes.issue(SHARED)
        self.assertEqual(self.call("POST", "/v1/pair", body={"code": code, "name": "A"})[0], 200)
        self.assertEqual(self.call("POST", "/v1/pair", body={"code": code, "name": "B"})[0], 401)

    def test_an_owner_code_needs_a_name_and_is_not_used_up_by_asking_without_one(self):
        code = self.codes.issue(SHARED, "owner")
        status, body = self.call("POST", "/v1/pair", body={"code": code})
        self.assertEqual((status, body["error"]), (400, "name_required"))
        status, body = self.call("POST", "/v1/pair", body={"code": code, "name": "Mac"})
        self.assertEqual((status, body["role"]), (200, "owner"))

    def test_the_shared_token_and_viewers_still_read_usage(self):
        viewer = self.pair("Phone")["token"]
        self.assertEqual(self.call("GET", "/v1/usage", SHARED)[0], 200)
        self.assertEqual(self.call("GET", "/v1/usage", viewer)[0], 200)
        self.assertEqual(self.call("GET", "/v1/usage")[0], 401)
        self.assertEqual(self.call("GET", "/v1/usage", "mkd_zz_nope")[0], 401)

    def test_pairing_endpoints_are_for_the_shared_token_on_this_machine(self):
        viewer = self.pair("Phone")["token"]
        owner = self.pair("Mac", "owner")["token"]
        self.assertEqual(self.call("GET", "/v1/pairing", SHARED)[0], 200)
        self.assertEqual(self.call("GET", "/v1/pairing", viewer)[0], 403)
        self.assertEqual(self.call("GET", "/v1/pairing", owner)[0], 403)
        self.assertEqual(self.call("GET", "/v1/pairing", SHARED, headers=REMOTE)[0], 403)  # via a proxy
        status, info = self.call("GET", "/v1/pairing?role=owner", SHARED)
        self.assertEqual((status, info["role"]), (200, "owner"))
        self.assertEqual(self.codes.peek_role(info["link"].split("code=")[1]), "owner")
        self.assertEqual(self.call("GET", "/v1/pairing?role=root", SHARED)[0], 400)


class DeviceApiTests(ServerCase):
    def test_a_viewer_gets_403_on_device_management(self):
        viewer = self.pair("Phone")["token"]
        self.assertEqual(self.call("GET", "/v1/devices", viewer)[0], 403)
        self.assertEqual(self.call("DELETE", "/v1/devices/abcd", viewer)[0], 403)
        self.assertEqual(self.call("POST", "/v1/devices/pairing-codes", viewer, body={})[0], 403)

    def test_me_says_what_kind_of_machine_this_is(self):
        viewer = self.pair("Phone")["token"]
        status, me = self.call("GET", "/v1/me", viewer)
        self.assertEqual(status, 200)
        self.assertIn(me["platform"], ("linux", "macos"))
        self.assertIsInstance(me["headless"], bool)

    def test_an_owner_lists_devices_and_marks_itself(self):
        self.pair("Phone")
        owner = self.pair("Mac", "owner")
        status, body = self.call("GET", "/v1/devices", owner["token"], headers=REMOTE)
        self.assertEqual(status, 200)
        names = {d["name"]: d for d in body["devices"]}
        self.assertTrue(names["Mac"]["current"])
        self.assertFalse(names["Phone"]["current"])
        self.assertEqual(body["you"], {"role": "owner", "deviceId": owner["deviceId"]})
        self.assertEqual(body["sharedToken"]["label"], devices.SHARED_LABEL)
        self.assertNotIn("hash", json.dumps(body))
        self.assertNotIn(owner["token"], json.dumps(body))

    def test_the_shared_token_manages_devices_only_from_this_machine(self):
        self.pair("Phone")
        self.assertEqual(self.call("GET", "/v1/devices", SHARED)[0], 200)
        self.assertEqual(self.call("GET", "/v1/devices", SHARED, headers=REMOTE)[0], 403)

    def test_an_owner_revokes_a_viewer_who_then_gets_401(self):
        viewer = self.pair("Phone")
        owner = self.pair("Mac", "owner")["token"]
        status, body = self.call("DELETE", "/v1/devices/" + viewer["deviceId"], owner, headers=REMOTE)
        self.assertEqual(status, 200)
        self.assertEqual(body["revoked"]["name"], "Phone")
        self.assertFalse(body["selfRevoked"])
        self.assertEqual(self.call("GET", "/v1/usage", viewer["token"])[0], 401)
        self.assertEqual(self.call("DELETE", "/v1/devices/" + viewer["deviceId"], owner)[0], 404)
        self.assertEqual(self.call("GET", "/v1/usage", owner)[0], 200)

    def test_a_remote_owner_cannot_revoke_the_last_owner(self):
        owner = self.pair("Mac", "owner")
        status, body = self.call("DELETE", "/v1/devices/" + owner["deviceId"], owner["token"], headers=REMOTE)
        self.assertEqual((status, body["error"]), (409, "last_owner"))
        self.assertIn("meterkat devices revoke", body["message"])
        self.assertEqual(self.call("GET", "/v1/usage", owner["token"])[0], 200)
        # The machine itself (shared token, no proxy) can.
        self.assertEqual(self.call("DELETE", "/v1/devices/" + owner["deviceId"], SHARED)[0], 200)

    def test_an_owner_can_revoke_itself_when_another_owner_remains(self):
        first = self.pair("Mac", "owner")
        self.pair("Laptop", "owner")
        status, body = self.call("DELETE", "/v1/devices/" + first["deviceId"], first["token"], headers=REMOTE)
        self.assertEqual((status, body["selfRevoked"]), (200, True))

    def test_an_owner_hands_out_viewer_codes_only(self):
        owner = self.pair("Mac", "owner")["token"]
        status, info = self.call("POST", "/v1/devices/pairing-codes", owner, body={}, headers=REMOTE)
        self.assertEqual((status, info["role"], info["expiresInSeconds"]), (200, "viewer", 300))
        self.assertTrue(info["link"].startswith("meterkat://pair?"))
        code = info["link"].split("code=")[1]
        self.assertEqual(self.codes.peek_role(code), "viewer")
        self.assertEqual(self.call("POST", "/v1/devices/pairing-codes", owner, body={"role": "owner"})[0], 403)

    def test_a_revoke_ends_a_long_poll_that_is_already_waiting(self):
        viewer = self.pair("Phone")
        results = []

        def wait():
            results.append(self.call("GET", "/v1/usage?since=t1&wait=30", viewer["token"], timeout=20))

        thread = threading.Thread(target=wait)
        thread.start()
        time.sleep(0.3)
        started = time.monotonic()
        self.store.revoke(viewer["deviceId"], host=True)  # `meterkat devices revoke` in another process
        thread.join(15)
        self.assertEqual(results[0][0], 401)
        self.assertLess(time.monotonic() - started, meterkat.REVOKE_CHECK_SECONDS + 2)  # no new snapshot needed

    def test_a_long_poll_for_a_valid_device_returns_the_new_snapshot(self):
        viewer = self.pair("Phone")
        results = []
        thread = threading.Thread(target=lambda: results.append(
            self.call("GET", "/v1/usage?since=t1&wait=30", viewer["token"], timeout=20)))
        thread.start()
        time.sleep(0.3)
        self.poller.publish("t2")
        thread.join(10)
        self.assertEqual((results[0][0], results[0][1]["generatedAt"]), (200, "t2"))

    def test_last_active_follows_requests(self):
        viewer = self.pair("Phone")
        owner = self.pair("Mac", "owner")["token"]
        before = {d["id"]: d for d in self.call("GET", "/v1/devices", owner)[1]["devices"]}
        self.assertIsNone(before[viewer["deviceId"]]["lastUsedAt"])
        self.call("GET", "/v1/usage", viewer["token"])
        after = {d["id"]: d for d in self.call("GET", "/v1/devices", owner)[1]["devices"]}
        self.assertIsNotNone(after[viewer["deviceId"]]["lastUsedAt"])
        self.store.flush()
        with open(self.path) as f:
            saved = {d["id"]: d for d in json.load(f)["devices"]}
        self.assertIsNotNone(saved[viewer["deviceId"]]["lastUsedAt"])

    def test_bad_tokens_lock_a_remote_address_out_but_not_this_machine(self):
        for _ in range(5):
            self.assertEqual(self.call("GET", "/v1/usage", "mkd_aa_wrong", headers=REMOTE)[0], 401)
        status, body = self.call("GET", "/v1/usage", SHARED, headers=REMOTE)
        self.assertEqual((status, body["error"]), (429, "too_many_attempts"))
        for _ in range(8):
            self.assertEqual(self.call("GET", "/v1/usage", "wrong")[0], 401)  # this machine is never locked out
        self.assertEqual(self.call("GET", "/v1/usage", SHARED)[0], 200)

    def test_bad_pairing_codes_count_too(self):
        for _ in range(5):
            self.assertEqual(self.call("POST", "/v1/pair", body={"code": "nope", "name": "x"}, headers=REMOTE)[0], 401)
        self.assertEqual(self.call("POST", "/v1/pair", body={"code": "nope"}, headers=REMOTE)[0], 429)


class CliTests(StoreCase):
    def run_cli(self, *argv, stdin_tty=False):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(meterkat, "CONFIG_PATH", self.path), mock.patch.object(meterkat, "CONFIG_DIR", self.dir.name), \
                mock.patch.object(meterkat, "load_config", lambda: {"token": SHARED, "port": 47300}), \
                mock.patch("sys.stdin.isatty", return_value=stdin_tty), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = meterkat.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_list_shows_name_role_times_and_id_never_a_secret(self):
        token, home = self.store.mint("Home Assistant")
        _, phone = self.store.mint("Phone", "owner")
        self.store.touch(home["id"])
        code, out, _ = self.run_cli("devices")
        self.assertEqual(code, 0)
        for text in ("NAME", "ROLE", "AUTHORIZED", "LAST ACTIVE", "ID", "Home Assistant", "Phone", "owner",
                     home["id"], "just now", "never", devices.SHARED_LABEL, "rotate-token"):
            self.assertIn(text, out)
        self.assertNotIn(token, out)
        self.assertNotIn(devices.hash_token(token), out)
        self.assertIn("…" + home["hint"], out)

    def test_list_is_newest_first(self):
        _, old = self.store.mint("Old")
        cfg = devices.read_config(self.path)
        cfg["devices"][0]["createdAt"] = "2020-01-01T00:00:00Z"
        devices.write_config(self.path, cfg)
        self.store.mint("New")
        _, out, _ = self.run_cli("devices")
        self.assertLess(out.index("New"), out.index("Old"))

    def test_json(self):
        token, record = self.store.mint("Phone")
        _, out, _ = self.run_cli("devices", "--json")
        data = json.loads(out)
        self.assertEqual(data["devices"][0]["id"], record["id"])
        self.assertEqual(data["sharedToken"]["name"], devices.SHARED_LABEL)
        self.assertNotIn(token, out)
        self.assertNotIn("hash", out)
        _, out, _ = self.run_cli("devices", "list", "--json")
        self.assertEqual(json.loads(out)["devices"][0]["id"], record["id"])

    def test_empty(self):
        _, out, _ = self.run_cli("devices")
        self.assertIn("No paired devices yet", out)
        self.assertIn(devices.SHARED_LABEL, out)

    def test_revoke_by_id(self):
        token, record = self.store.mint("Phone")
        code, out, _ = self.run_cli("devices", "revoke", record["id"], "--yes")
        self.assertEqual(code, 0)
        self.assertIn("Revoked", out)
        self.assertIsNone(devices.DeviceStore(self.path).authenticate(token))
        with open(os.path.join(self.dir.name, "audit.log")) as f:
            self.assertIn("by the host CLI", f.read())

    def test_revoke_by_name_can_take_an_owner(self):
        _, record = self.store.mint("Mac", "owner")
        code, out, _ = self.run_cli("devices", "revoke", "mac", "--yes")
        self.assertEqual(code, 0)
        self.assertEqual(devices.DeviceStore(self.path).records(), [])

    def test_revoke_asks_first(self):
        token, record = self.store.mint("Phone")
        with mock.patch("builtins.input", return_value="n"):
            code, out, _ = self.run_cli("devices", "revoke", record["id"], stdin_tty=True)
        self.assertEqual(code, 1)
        self.assertTrue(devices.DeviceStore(self.path).authenticate(token))
        with mock.patch("builtins.input", return_value="y"):
            code, out, _ = self.run_cli("devices", "revoke", record["id"], stdin_tty=True)
        self.assertEqual(code, 0)
        self.assertIsNone(devices.DeviceStore(self.path).authenticate(token))

    def test_revoke_needs_yes_without_a_terminal(self):
        _, record = self.store.mint("Phone")
        code, _, err = self.run_cli("devices", "revoke", record["id"])
        self.assertEqual(code, 1)
        self.assertIn("--yes", err)

    def test_revoke_unknown_and_ambiguous(self):
        self.store.mint("Same")
        self.store.mint("Same")
        self.assertEqual(self.run_cli("devices", "revoke", "nobody", "--yes")[0], 1)
        code, _, err = self.run_cli("devices", "revoke", "same", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("matches 2 devices", err)

    def test_there_is_no_command_that_creates_a_token(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            meterkat.build_parser().parse_args(["devices", "create"])


class MachineInfoTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(meterkat, "_headless_cache", (0.0, None))
        patcher.start()
        self.addCleanup(patcher.stop)
        mac = mock.patch.object(meterkat, "IS_MAC", False)
        mac.start()
        self.addCleanup(mac.stop)

    def run_with(self, sessions, types):
        def fake(args, timeout=5):
            if args[:2] == ["loginctl", "list-sessions"]:
                return sessions
            return types.get(args[2])
        with mock.patch.object(meterkat, "run_cmd", fake), mock.patch.object(meterkat.sys, "platform", "linux"):
            return meterkat.machine_info()

    def test_ssh_sessions_only_is_headless(self):
        info = self.run_with("1 1000 sahil seat0\n2 1000 sahil\n", {"1": "tty", "2": "tty"})
        self.assertEqual(info, {"platform": "linux", "headless": True})

    def test_a_graphical_session_is_not_headless(self):
        self.assertFalse(self.run_with("2 1000 sahil seat0\n", {"2": "wayland"})["headless"])

    def test_without_loginctl_it_falls_back_to_the_display(self):
        with mock.patch.object(meterkat, "run_cmd", lambda *a, **k: None), \
                mock.patch.object(meterkat.sys, "platform", "linux"), \
                mock.patch.dict(os.environ, {"DISPLAY": ":0"}):
            self.assertFalse(meterkat.machine_info()["headless"])

    def test_a_mac_is_never_headless(self):
        with mock.patch.object(meterkat, "IS_MAC", True):
            self.assertEqual(meterkat.machine_info(), {"platform": "macos", "headless": False})


class DiscoveryTests(unittest.TestCase):
    def test_commands(self):
        txt = {"version": "2.5.0", "id": "abc", "host": "box", "skip": None}
        mac = discovery.command("box", 47300, txt, which=lambda n: "/usr/bin/" + n, platform="darwin")
        self.assertEqual(mac[:6], ["/usr/bin/dns-sd", "-R", "box", "_meterkat._tcp", ".", "47300"])
        self.assertIn("id=abc", mac)
        self.assertNotIn("skip=None", mac)
        linux = discovery.command("box", 47300, txt, which=lambda n: "/usr/bin/" + n, platform="linux")
        self.assertEqual(linux[:4], ["/usr/bin/avahi-publish-service", "box", "_meterkat._tcp", "47300"])

    def test_no_tool_means_no_announcement(self):
        announcer = discovery.Announcer("box", 47300, {}, which=lambda n: None)
        self.assertFalse(announcer.start())

    def test_a_failing_tool_is_ignored_and_a_working_one_is_stopped(self):
        def broken(*a, **k):
            raise OSError("nope")
        self.assertFalse(discovery.Announcer("box", 1, {}, popen=broken, which=lambda n: "/x").start())
        process = mock.Mock()
        announcer = discovery.Announcer("box", 1, {}, popen=lambda *a, **k: process, which=lambda n: "/x")
        self.assertTrue(announcer.start())
        announcer.stop()
        process.terminate.assert_called_once()
        announcer.stop()  # a second stop does nothing

    def test_can_be_turned_off(self):
        with mock.patch.object(discovery, "Announcer") as cls:
            self.assertIsNone(meterkat.start_announcing({"announce": False}, 47300))
            cls.assert_not_called()


if __name__ == "__main__":
    unittest.main()
