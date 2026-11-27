"""Per-device access tokens for the Meterkat companion (standard library only).

Every pairing creates its own token, `mkd_<id>_<secret>`. config.json keeps only
the id, name, role, times, a short hint and the sha256 of the token, never the
token. The running service and the `meterkat devices` CLI both read and write
config.json, so every write takes a file lock and re-reads the file first, and
the service notices a revoke by watching the file's stamp, with no restart.
"""

import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from datetime import datetime, timezone

TOKEN_PREFIX = "mkd"
ROLES = ("viewer", "owner")
DEFAULT_NAME = "Unnamed device"
MAX_NAME = 64
MAX_DEVICES = 100
PERSIST_SECONDS = 60  # last-active times reach config.json at most this often
SHARED_LABEL = "Shared token (older app versions)"

# config.json keys that the service writes while it runs. save_config() keeps the
# on-disk values, so a CLI command holding an older copy can't undo a pairing.
SERVICE_KEYS = ("devices", "sharedLastUsedAt")


class DeviceError(Exception):
    """A refused device operation. `code` is a short machine name."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def relative(iso, now=None):
    """'3 days ago' for an ISO time, 'never' for none."""
    then = parse_iso(iso)
    if then is None:
        return "never"
    seconds = int(((now or datetime.now(timezone.utc)) - then).total_seconds())
    if seconds < 60:
        return "just now"
    for size, unit in ((86400, "day"), (3600, "hour"), (60, "minute")):
        if seconds >= size:
            count = seconds // size
            return "%d %s%s ago" % (count, unit, "" if count == 1 else "s")
    return "just now"


def local_stamp(iso):
    """'2026-10-25 14:05' in this machine's time zone."""
    then = parse_iso(iso)
    return then.astimezone().strftime("%Y-%m-%d %H:%M") if then else "never"


def hash_token(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def token_id(token):
    """The id inside a device token, or None when it isn't shaped like one."""
    if not isinstance(token, str):
        return None
    prefix, _, rest = token.partition("_")
    ident, _, secret = rest.partition("_")
    if prefix != TOKEN_PREFIX or not ident or not secret:
        return None
    return ident


def clean_name(name):
    text = "".join(ch for ch in str(name or "") if ch.isprintable()).strip()
    return text[:MAX_NAME] or DEFAULT_NAME


# --------------------------------------------------------------------------
# config.json access
# --------------------------------------------------------------------------

@contextlib.contextmanager
def file_lock(path):
    """Serializes read-modify-write cycles on config.json across processes."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # releases the lock


def read_config(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_config(path, cfg):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def keep_service_keys(path, cfg):
    """Copies the service-written keys from the file into `cfg` (called with the lock held)."""
    disk = read_config(path)
    for key in SERVICE_KEYS:
        if key in disk:
            cfg[key] = disk[key]
        else:
            cfg.pop(key, None)
    return cfg


def _stamp(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size, st.st_ino)


def _valid(record):
    return (isinstance(record, dict) and isinstance(record.get("id"), str) and record["id"]
            and isinstance(record.get("hash"), str) and record.get("role") in ROLES)


# --------------------------------------------------------------------------
# The device list
# --------------------------------------------------------------------------

class DeviceStore:
    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()
        self._stamp = None
        self._devices = {}
        self._shared_last = None
        self._dirty = set()  # device ids (and "shared") with a newer lastUsedAt than the file
        self._persisted_at = 0.0

    # -- reading --

    def _load(self, cfg):
        old = self._devices
        devices = {}
        for record in cfg.get("devices") or []:
            if _valid(record):
                record = dict(record)
                kept = old.get(record["id"])
                if kept and (kept.get("lastUsedAt") or "") > (record.get("lastUsedAt") or ""):
                    record["lastUsedAt"] = kept["lastUsedAt"]
                devices[record["id"]] = record
        self._devices = devices
        disk_shared = cfg.get("sharedLastUsedAt")
        self._shared_last = max(filter(None, (self._shared_last, disk_shared)), default=None)
        self._dirty &= set(devices) | {"shared"}

    def _refresh(self):
        stamp = _stamp(self.path)
        if stamp != self._stamp:
            self._load(read_config(self.path))
            self._stamp = stamp

    def records(self):
        """Every device, newest first, as copies."""
        with self._lock:
            self._refresh()
            return sorted((dict(r) for r in self._devices.values()),
                          key=lambda r: r.get("createdAt") or "", reverse=True)

    def shared_last_used(self):
        with self._lock:
            self._refresh()
            return self._shared_last

    def owner_count(self):
        return sum(1 for r in self.records() if r["role"] == "owner")

    def authenticate(self, token):
        """The device record for a valid, unrevoked token, else None."""
        ident = token_id(token)
        if ident is None:
            return None
        with self._lock:
            self._refresh()
            record = self._devices.get(ident)
            if record and hmac.compare_digest(record["hash"], hash_token(token)):
                return dict(record)
        return None

    def exists(self, ident):
        """True while the device hasn't been revoked."""
        with self._lock:
            self._refresh()
            return ident in self._devices

    # -- last active --

    def touch(self, ident):
        """Marks a device (or "shared") active now. Cheap: memory only, plus one file write a minute."""
        now = now_iso()
        with self._lock:
            self._refresh()
            first = False
            if ident == "shared":
                first = self._shared_last is None
                self._shared_last = now
            elif ident in self._devices:
                first = self._devices[ident].get("lastUsedAt") is None
                self._devices[ident]["lastUsedAt"] = now
            else:
                return
            self._dirty.add(ident)
            # A device's first request is written at once, so a new pairing doesn't read
            # "never" for a minute; after that, at most one write a minute.
            if first or time.monotonic() - self._persisted_at >= PERSIST_SECONDS:
                self._persist()

    def _persist(self):
        self._persisted_at = time.monotonic()
        dirty, self._dirty = self._dirty, set()
        try:
            with file_lock(self.path):
                cfg = read_config(self.path)
                changed = False
                for record in cfg.get("devices") or []:
                    mine = self._devices.get(record.get("id")) if record.get("id") in dirty else None
                    if mine and (mine.get("lastUsedAt") or "") > (record.get("lastUsedAt") or ""):
                        record["lastUsedAt"] = mine["lastUsedAt"]
                        changed = True
                if "shared" in dirty and self._shared_last:
                    cfg["sharedLastUsedAt"] = self._shared_last
                    changed = True
                if changed:
                    write_config(self.path, cfg)
                    self._stamp = None  # the file may hold changes we haven't read: reload next time
        except OSError:
            self._dirty |= dirty  # try again next time

    def flush(self):
        with self._lock:
            if self._dirty:
                self._persist()

    # -- changing --

    def mint(self, name, role="viewer"):
        """Creates a device and returns (token, record). The token is shown once and never stored."""
        if role not in ROLES:
            raise DeviceError("bad_role", "Unknown role.")
        with self._lock, file_lock(self.path):
            cfg = read_config(self.path)
            devices = [d for d in cfg.get("devices") or [] if _valid(d)]
            if len(devices) >= MAX_DEVICES:
                raise DeviceError("too_many", "Too many paired devices; revoke some first.")
            taken = {d["id"] for d in devices}
            ident = secrets.token_hex(4)
            while ident in taken:
                ident = secrets.token_hex(4)
            secret = secrets.token_urlsafe(32)
            token = "%s_%s_%s" % (TOKEN_PREFIX, ident, secret)
            record = {"id": ident, "name": clean_name(name), "role": role, "createdAt": now_iso(),
                      "lastUsedAt": None, "hint": secret[-4:], "hash": hash_token(token)}
            devices.append(record)
            cfg["devices"] = devices
            write_config(self.path, cfg)
            self._stamp = None  # re-read on the next request
        return token, dict(record)

    def revoke(self, ident, host=False):
        """Removes one device and returns its record.

        `ident` is an id, a unique id prefix, or (for `host`) a name. Without `host`, the
        last owner can't be revoked: only the machine's own CLI may do that."""
        with self._lock, file_lock(self.path):
            cfg = read_config(self.path)
            devices = [d for d in cfg.get("devices") or [] if _valid(d)]
            target = resolve(devices, ident, by_name=host)
            if target["role"] == "owner" and not host:
                if sum(1 for d in devices if d["role"] == "owner") <= 1:
                    raise DeviceError("last_owner", "This is the last owner device. Revoke it with "
                                      "`meterkat devices revoke` on the machine that runs the companion.")
            cfg["devices"] = [d for d in devices if d["id"] != target["id"]]
            write_config(self.path, cfg)
            self._stamp = None
        return dict(target)


def resolve(devices, ident, by_name=True):
    """The one device matching `ident`: exact id, unique id prefix, or case-insensitive name."""
    ident = str(ident or "").strip()
    if not ident:
        raise DeviceError("not_found", "No device given.")
    exact = [d for d in devices if d["id"] == ident]
    if not exact:
        exact = [d for d in devices if len(ident) >= 3 and d["id"].startswith(ident)]
    if not exact and by_name:
        exact = [d for d in devices if d.get("name", "").lower() == ident.lower()]
    if len(exact) == 1:
        return exact[0]
    if not exact:
        raise DeviceError("not_found", "No paired device matches %r." % ident)
    raise DeviceError("ambiguous", "%r matches %d devices (%s). Use an id." %
                      (ident, len(exact), ", ".join(d["id"] for d in exact)))


def public(record, current=False):
    """What clients and the CLI may see of a device: never the hash."""
    return {"id": record["id"], "name": record.get("name") or DEFAULT_NAME, "role": record["role"],
            "createdAt": record.get("createdAt"), "lastUsedAt": record.get("lastUsedAt"),
            "hint": record.get("hint"), "current": bool(current)}


def append_audit(config_dir, message):
    """One line per revoke in ~/.config/meterkat/audit.log (mode 600)."""
    try:
        os.makedirs(config_dir, exist_ok=True)
        fd = os.open(os.path.join(config_dir, "audit.log"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write("%s %s\n" % (now_iso(), message))
    except OSError:
        pass


# --------------------------------------------------------------------------
# Lockout
# --------------------------------------------------------------------------

class AuthGuard:
    """Blocks a source address for a while after repeated bad credentials."""

    def __init__(self, limit=10, window=300, block=300, clock=time.monotonic):
        self.limit, self.window, self.block, self.clock = limit, window, block, clock
        self._failures = {}
        self._blocked = {}
        self._lock = threading.Lock()

    def retry_after(self, ip):
        """Seconds left on a block, or 0."""
        with self._lock:
            until = self._blocked.get(ip)
            if until is None:
                return 0
            left = until - self.clock()
            if left <= 0:
                del self._blocked[ip]
                return 0
            return int(left) + 1

    def fail(self, ip):
        with self._lock:
            now = self.clock()
            recent = [t for t in self._failures.get(ip, []) if now - t < self.window] + [now]
            if len(recent) >= self.limit:
                self._blocked[ip] = now + self.block
                recent = []
            self._failures[ip] = recent
            if len(self._failures) > 1024:  # keep the table small under a scan
                for key in [k for k, v in self._failures.items() if not v or now - v[-1] >= self.window]:
                    del self._failures[key]

    def ok(self, ip):
        with self._lock:
            self._failures.pop(ip, None)
