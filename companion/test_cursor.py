import base64
import os
import sqlite3
import tempfile
import unittest
from unittest import mock

import meterkat

SEALED = "cursor-safe-storage:v1:" + base64.b64encode(b"fake-sealed-bytes").decode()


def make_db(folder, token):
    path = os.path.join(folder, "state.vscdb")
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
    conn.executemany("INSERT INTO ItemTable VALUES (?, ?)", [
        ("cursorAuth/accessToken", token),
        ("cursorAuth/cachedEmail", "fake@example.com"),
        ("cursorAuth/stripeMembershipType", "pro"),
    ])
    conn.commit()
    conn.close()
    return path


class CursorSealedTokenTests(unittest.TestCase):
    def fetch(self, token):
        with tempfile.TemporaryDirectory() as folder:
            path = make_db(folder, token)
            with mock.patch.object(meterkat, "cursor_state_db", return_value=path), \
                    mock.patch.object(meterkat, "http_get_json") as http:
                return meterkat.fetch_cursor(), http, meterkat._detect_cursor()

    def test_sealed_token_reports_error_without_http(self):
        for token in (SEALED, "cursor-safe-storage:v2:" + "QUJD"):
            result, http, _ = self.fetch(token)
            self.assertEqual(result["status"], "error")
            self.assertEqual(result["error"], meterkat.CURSOR_SEALED)
            self.assertEqual(result["error"], "Cursor stores its login encrypted; Meterkat can't read it yet.")
            self.assertEqual(result["plan"], "pro")
            self.assertEqual(result["account"], "fake@example.com")
            http.assert_not_called()

    def test_detect_says_unreadable(self):
        _, _, detected = self.fetch(SEALED)
        self.assertEqual(detected, (None, meterkat.CURSOR_SEALED))

    def test_plain_token_still_goes_through_jwt_path(self):
        result, http, detected = self.fetch("not-a-jwt")
        self.assertEqual(result["error"], "Unrecognised Cursor session token — sign in to Cursor again.")
        http.assert_not_called()
        self.assertEqual(detected, ("Cursor app", None))


if __name__ == "__main__":
    unittest.main()
