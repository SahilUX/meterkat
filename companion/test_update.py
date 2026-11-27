import os
import subprocess
import tempfile
import unittest
from unittest import mock

import meterkat

HERE = os.path.dirname(os.path.realpath(meterkat.__file__))


class UpdateTests(unittest.TestCase):
    def update(self, source, **flags):
        args = mock.Mock(source=source, no_pull=False, force=False)
        for name, value in flags.items():
            setattr(args, name, value)
        # Not a git checkout, so nothing is pulled.
        with mock.patch.object(meterkat, "run_cmd", return_value=None), mock.patch("sys.stdout"):
            return meterkat.cmd_update(args, {})

    def test_without_a_recorded_source_it_says_how_to_record_one(self):
        with mock.patch("builtins.open", side_effect=OSError):
            self.assertEqual(self.update(None), 1)

    def test_a_folder_without_install_sh_is_refused(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(self.update(empty), 1)

    def test_the_checkout_it_runs_from_is_already_up_to_date(self):
        with mock.patch.object(subprocess, "run") as run:
            self.assertEqual(self.update(HERE), 0)
        run.assert_not_called()

    def test_repo_root_resolves_to_the_companion_folder(self):
        with mock.patch.object(subprocess, "run") as run:
            self.assertEqual(self.update(os.path.dirname(HERE)), 0)
        run.assert_not_called()

    def test_source_version_reads_the_version_line(self):
        self.assertEqual(meterkat.source_version(os.path.join(HERE, "meterkat.py")), meterkat.VERSION)


if __name__ == "__main__":
    unittest.main()
