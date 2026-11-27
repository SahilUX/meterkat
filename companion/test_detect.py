import json
import os
import tempfile
import unittest
from unittest import mock

import meterkat


class DetectTests(unittest.TestCase):
    def setUp(self):
        # No saved keys or OpenCode keys unless a test adds them.
        patches = [
            mock.patch.object(meterkat, "saved_api_key", lambda pid: None),
            mock.patch.object(meterkat, "opencode_saved_key", lambda *names: None),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def provider(self, pid, cfg=None):
        return next(p for p in meterkat.detect_providers(cfg or {}) if p["id"] == pid)

    def test_codex_sign_in_is_found(self):
        with tempfile.TemporaryDirectory() as home:
            with open(os.path.join(home, "auth.json"), "w") as f:
                json.dump({"tokens": {"access_token": "secret"}}, f)
            with mock.patch.dict(os.environ, {"CODEX_HOME": home}):
                p = self.provider("openai")
        self.assertTrue(p["found"])
        self.assertIsNone(p["hint"])
        self.assertNotIn("secret", json.dumps(p))

    def test_key_only_in_shell_is_not_found(self):
        with mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": "sk-or-secret"}):
            p = self.provider("openrouter")
        self.assertFalse(p["found"])
        self.assertIn("$OPENROUTER_API_KEY", p["hint"])
        self.assertTrue(p["takesKey"])
        self.assertNotIn("sk-or-secret", json.dumps(p))

    def test_disabled_provider_is_reported(self):
        p = self.provider("gemini", {"disabledProviders": ["gemini"]})
        self.assertFalse(p["enabled"])

    def test_failing_detector_keeps_the_others(self):
        def broken():
            raise OSError("boom")
        with mock.patch.dict(meterkat.DETECTORS, {"cursor": broken}):
            providers = meterkat.detect_providers({})
        cursor = next(p for p in providers if p["id"] == "cursor")
        self.assertFalse(cursor["found"])
        self.assertIn("boom", cursor["hint"])
        self.assertEqual(len(providers), len(meterkat.PROVIDERS))


if __name__ == "__main__":
    unittest.main()
