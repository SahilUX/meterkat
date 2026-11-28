#!/bin/sh
# Install the latest published Meterkat release; use main before the first release.
set -eu
command -v python3 >/dev/null 2>&1 || { echo "Install Python 3.9 or newer first." >&2; exit 1; }
python3 - "$@" <<'PYTHON'
import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

if sys.version_info < (3, 9):
    raise SystemExit("Meterkat requires Python 3.9 or newer")

def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "meterkat-installer"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()

# The releases list includes pre-releases, unlike /releases/latest.
releases = json.loads(fetch("https://api.github.com/repos/SahilUX/meterkat/releases?per_page=100"))
release = next((item for item in releases if not item["draft"]), None)
if release:
    url = release["tarball_url"]
else:
    url = "https://api.github.com/repos/SahilUX/meterkat/tarball/main"
with tempfile.TemporaryDirectory(prefix="meterkat-install-") as temporary:
    root = pathlib.Path(temporary)
    with tarfile.open(fileobj=io.BytesIO(fetch(url)), mode="r:gz") as archive:
        # Source archives need only regular files and directories. Reject links,
        # devices and paths that could write outside the temporary directory.
        for member in archive.getmembers():
            target = (root / member.name).resolve()
            if root not in target.parents or not (member.isfile() or member.isdir()):
                raise SystemExit("Unsafe path in source archive")
        archive.extractall(root)
    installers = list(root.glob("*/companion/install.sh"))
    if len(installers) != 1:
        raise SystemExit("Source archive does not contain companion/install.sh")
    environment = dict(os.environ, METERKAT_INSTALL_SOURCE="release")
    # stdin belongs to this bootstrap. Users can run meterkat setup afterwards.
    subprocess.run(["/bin/sh", str(installers[0]), *sys.argv[1:]], env=environment, check=True)
PYTHON
