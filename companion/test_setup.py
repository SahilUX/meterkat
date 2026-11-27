import builtins
import unittest
from unittest import mock

import meterkat


def provider(pid, found, enabled=True):
    return {"id": pid, "name": pid.title(), "found": found, "source": "here" if found else None,
            "hint": None if found else "sign in", "enabled": enabled,
            "takesKey": pid in meterkat.API_KEY_KEYS, "savedKey": False}


class SetupTests(unittest.TestCase):
    def run_setup(self, providers, answers, yes=False):
        cfg = {"token": "t", "port": 47300}
        args = mock.Mock(yes=yes)
        replies = iter(answers)
        with mock.patch.object(meterkat, "detect_providers", lambda c: providers), \
                mock.patch.object(meterkat, "save_config", lambda c: None), \
                mock.patch.object(meterkat, "install", return_value=0) as install, \
                mock.patch.object(meterkat, "print_pairing"), \
                mock.patch.object(builtins, "input", lambda prompt="": next(replies)), \
                mock.patch.object(meterkat, "ask_secret", lambda prompt: next(replies)), \
                mock.patch("sys.stdout"):
            code = meterkat.cmd_setup(args, cfg)
        return code, cfg, install

    def test_yes_tracks_what_was_found_and_installs(self):
        code, cfg, install = self.run_setup([provider("claude", True), provider("cursor", False)], [], yes=True)
        self.assertEqual(code, 0)
        self.assertEqual(cfg["disabledProviders"], [p for p in meterkat.PROVIDER_IDS if p != "claude"])
        install.assert_called_once()

    def test_answers_override_suggestions_and_save_a_key(self):
        providers = [provider("claude", True), provider("openrouter", False)]
        # All detected? n. Track Claude? n. Track OpenRouter? y, key, then install? n.
        code, cfg, install = self.run_setup(providers, ["n", "n", "y", "sk-or-1", "n"])
        self.assertEqual(cfg["disabledProviders"], ["claude"] + [p for p in meterkat.PROVIDER_IDS
                                                                 if p not in ("claude", "openrouter")])
        self.assertEqual(cfg["openrouterKey"], "sk-or-1")
        install.assert_not_called()

    def test_turn_on_all_detected(self):
        providers = [provider("claude", True), provider("gemini", True, enabled=False),
                     provider("cursor", False), provider("openrouter", False)]
        # All detected? Enter. Add a key for OpenRouter? Enter (no). Install? y.
        code, cfg, install = self.run_setup(providers, ["", "", "y"])
        self.assertEqual(set(meterkat.PROVIDER_IDS) - set(cfg["disabledProviders"]), {"claude", "gemini"})
        self.assertNotIn("openrouterKey", cfg)
        install.assert_called_once()
        self.assertFalse(install.call_args.kwargs["show_pairing"])

    def test_a_key_turns_on_a_provider_after_all_detected(self):
        providers = [provider("claude", True), provider("openrouter", False)]
        code, cfg, install = self.run_setup(providers, ["y", "y", "sk-or-2", "n"])
        self.assertEqual(set(meterkat.PROVIDER_IDS) - set(cfg["disabledProviders"]), {"claude", "openrouter"})
        self.assertEqual(cfg["openrouterKey"], "sk-or-2")

    def test_rerun_keeps_the_current_choice(self):
        providers = [provider("claude", True, enabled=False), provider("gemini", False, enabled=True)]
        code, cfg, install = self.run_setup(providers, [], yes=True)
        self.assertNotIn("claude", set(meterkat.PROVIDER_IDS) - set(cfg["disabledProviders"]))
        self.assertIn("gemini", set(meterkat.PROVIDER_IDS) - set(cfg["disabledProviders"]))

    def test_end_of_input_takes_defaults(self):
        def eof(prompt=""):
            raise EOFError
        cfg = {"token": "t", "port": 47300}
        with mock.patch.object(builtins, "input", eof), mock.patch("sys.stdout"):
            self.assertTrue(meterkat.ask_yes_no("Track?", True))
            self.assertFalse(meterkat.ask_yes_no("Track?", False))


class PairingTests(unittest.TestCase):
    def test_link_carries_the_hostname(self):
        with mock.patch.object(meterkat, "pairing_candidates", return_value=[]), \
                mock.patch.object(meterkat, "short_hostname", return_value="devbox"):
            codes = meterkat.PairingCodes()
            info = meterkat.pairing_info({"token": "tok", "localURL": "http://10.0.0.2:47300"}, 47300,
                                         pairing_codes=codes)
        self.assertTrue(info["link"].startswith(
            "meterkat://pair?local=http%3A%2F%2F10.0.0.2%3A47300&name=devbox&code="))
        self.assertNotIn("token=", info["link"])
        code = meterkat.urllib.parse.parse_qs(meterkat.urllib.parse.urlsplit(info["link"]).query)["code"][0]
        self.assertEqual(codes.redeem(code), "tok")
        self.assertIsNone(codes.redeem(code))


class UserBusTests(unittest.TestCase):
    def test_points_at_the_runtime_dir_when_unset(self):
        with mock.patch.dict("os.environ", {}, clear=True), \
                mock.patch("os.path.isdir", return_value=True), mock.patch("os.path.exists", return_value=True), \
                mock.patch("os.getuid", return_value=1000):
            self.assertTrue(meterkat.ensure_user_bus_env())
            import os
            self.assertEqual(os.environ["XDG_RUNTIME_DIR"], "/run/user/1000")
            self.assertEqual(os.environ["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/1000/bus")

    def test_keeps_an_existing_value(self):
        with mock.patch.dict("os.environ", {"XDG_RUNTIME_DIR": "/custom"}, clear=True):
            self.assertTrue(meterkat.ensure_user_bus_env())
            import os
            self.assertEqual(os.environ["XDG_RUNTIME_DIR"], "/custom")

    def test_reports_no_user_systemd(self):
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch("os.path.isdir", return_value=False):
            self.assertFalse(meterkat.ensure_user_bus_env())


if __name__ == "__main__":
    unittest.main()
