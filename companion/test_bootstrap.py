"""Exercise archive installation without starting a service or using the network."""
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import argparse

import meterkat

ROOT = Path(__file__).resolve().parent.parent


class BootstrapTests(unittest.TestCase):
    def run_bootstrap(self, releases, malicious=False, symlinked_temp=False):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w:gz') as tar:
            if malicious:
                item = tarfile.TarInfo('../escape')
                item.size = 1
                tar.addfile(item, io.BytesIO(b'x'))
            else:
                tar.add(ROOT / 'install.sh', arcname='source/install.sh')
                for path in (ROOT / 'companion').iterdir():
                    if path.suffix == '.py' or path.name == 'install.sh':
                        tar.add(path, arcname='source/companion/' + path.name)
        with tempfile.TemporaryDirectory() as temporary:
            temporary = Path(temporary)
            (temporary / 'archive').write_bytes(archive.getvalue())
            (temporary / 'releases').write_text(json.dumps(releases))
            script = (ROOT / 'install.sh').read_text().split("<<'PYTHON'\n", 1)[1].rsplit('\nPYTHON', 1)[0]
            prelude = '''
import io, pathlib, urllib.request
from unittest.mock import patch
fixture_root = pathlib.Path.cwd()
def fetch(request, **kwargs):
    url = request.full_url
    if '/releases?' in url:
        return io.BytesIO((fixture_root / 'releases').read_bytes())
    assert url == 'https://example.invalid/release.tar.gz' or url.endswith('/tarball/main'), url
    return io.BytesIO((fixture_root / 'archive').read_bytes())
patch('urllib.request.urlopen', side_effect=fetch).start()
'''
            environment = dict(os.environ, HOME=str(temporary), XDG_DATA_HOME=str(temporary / 'data'))
            if symlinked_temp:
                (temporary / 'real-temp').mkdir()
                (temporary / 'linked-temp').symlink_to(temporary / 'real-temp', target_is_directory=True)
                environment['TMPDIR'] = str(temporary / 'linked-temp')
            result = subprocess.run(['python3', '-c', prelude + script, '--files-only'],
                                    cwd=temporary, env=environment, capture_output=True, text=True)
            if malicious:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unsafe path', result.stderr)
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            installed = temporary / 'data/meterkat'
            self.assertEqual((installed / 'source').read_text().strip(), 'release')
            self.assertTrue((installed / 'bootstrap.sh').is_file())
            version = subprocess.check_output([str(temporary / '.local/bin/meterkat'), '--version'], env=environment, text=True)
            self.assertIn(meterkat.VERSION, version)

    def test_first_install_without_releases(self):
        self.run_bootstrap([])

    def test_prerelease_install(self):
        self.run_bootstrap([{'draft': True}, {'draft': False, 'tarball_url': 'https://example.invalid/release.tar.gz'}])

    def test_install_with_symlinked_temp_directory(self):
        self.run_bootstrap([], symlinked_temp=True)

    def test_archive_cannot_escape_temp_directory(self):
        self.run_bootstrap([], malicious=True)

    @mock.patch.object(meterkat, 'restart_service')
    @mock.patch.object(meterkat.os.path, 'exists', return_value=True)
    @mock.patch.object(meterkat.subprocess, 'run')
    def test_release_update_restarts_only_after_install(self, run, exists, restart):
        args = argparse.Namespace(source='release', no_pull=False, force=False)
        run.return_value.returncode = 1
        self.assertEqual(meterkat.cmd_update(args, {}), 1)
        restart.assert_not_called()
        run.return_value.returncode = 0
        restart.return_value = True
        self.assertEqual(meterkat.cmd_update(args, {}), 0)
        self.assertEqual(run.call_args.args[0][-1], '--files-only')
        restart.assert_called_once()
