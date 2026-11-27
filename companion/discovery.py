"""Announces the companion on the local network as `_meterkat._tcp` (best effort).

The standard library has no mDNS responder, so this runs the OS's own tool for as
long as the service lives: `dns-sd -R` on macOS, `avahi-publish-service` on Linux
when it's installed. Without a tool, or if it fails, nothing is announced and the
companion works as before. Home Assistant uses the announcement to offer setup.
"""

import atexit
import shutil
import subprocess
import sys

SERVICE_TYPE = "_meterkat._tcp"


def _die_with_parent():
    """Linux: have the kernel stop the publisher if the service is killed outright."""
    try:
        import ctypes
        import signal
        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except Exception:
        pass


def command(name, port, txt, which=shutil.which, platform=sys.platform):
    """The argv that publishes the service, or None when this machine has no tool for it."""
    records = ["%s=%s" % (key, value) for key, value in txt.items() if value is not None]
    if platform == "darwin":
        tool = which("dns-sd")
        return [tool, "-R", name, SERVICE_TYPE, ".", str(port)] + records if tool else None
    tool = which("avahi-publish-service")
    return [tool, name, SERVICE_TYPE, str(port)] + records if tool else None


class Announcer:
    def __init__(self, name, port, txt, popen=subprocess.Popen, which=shutil.which, platform=sys.platform):
        self.argv = command(name, port, txt, which, platform)
        self._popen = popen
        self.process = None

    def start(self):
        """True when an announcement is running."""
        if not self.argv:
            return False
        extra = {"preexec_fn": _die_with_parent} if sys.platform.startswith("linux") else {}
        try:
            self.process = self._popen(self.argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, **extra)
        except OSError:
            self.process = None
            return False
        atexit.register(self.stop)
        return True

    def stop(self):
        process, self.process = self.process, None
        if process is None:
            return
        try:
            process.terminate()
            process.wait(timeout=3)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
