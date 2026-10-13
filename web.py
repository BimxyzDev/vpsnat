#!/usr/bin/env python3
"""VPSNAT Web — UI + REST API di atas CLI `vpsnat` (stdlib only).

Admin : login UI (username/password) atau `Authorization: Bearer <WEB_API_KEY>`.
User  : login UI dengan nama VPS / port SSH + password root VPS.
Config: /etc/vpsnat/vpsnat.conf (WEB_*). Logika provisioning tetap di CLI Bash.
"""
import datetime
import functools
import hashlib
import hmac
import ipaddress
import json
import math
import os
import re
import secrets
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import zlib
from contextlib import contextmanager
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

SCRYPT = dict(n=2**14, r=8, p=1, dklen=32)


def hash_password(pw, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, **SCRYPT)
    return f"scrypt:{salt.hex()}:{dk.hex()}"


def verify_password(pw, stored):
    try:
        algo, salt_hex, hash_hex = stored.split(":")
        if algo != "scrypt":
            return False
        dk = hashlib.scrypt(pw.encode(), salt=bytes.fromhex(salt_hex), **SCRYPT)
        return hmac.compare_digest(dk.hex(), hash_hex)
    except Exception:
        return False


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "hashpw":
    print(hash_password(sys.stdin.read().rstrip("\r\n")))
    sys.exit(0)

APP_DIR = os.path.dirname(os.path.abspath(__file__))
CONF = os.environ.get("VPSNAT_WEB_CONF", "/etc/vpsnat/vpsnat.conf")
DB = os.environ.get("VPSNAT_WEB_DB", "/etc/vpsnat/vps.db")
CLI = os.environ.get("VPSNAT_WEB_CLI", "/usr/local/bin/vpsnat")
LXC = (
    os.environ.get("VPSNAT_WEB_LXC")
    or shutil.which("lxc", path=os.environ.get("PATH", "") + ":/snap/bin")
    or "/snap/bin/lxc"
)
COOKIE = "vpsnat_session"
MAX_BODY = 65536
DUMMY_HASH = hash_password("dummy-password-for-timing")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
PASS_RE = re.compile(r"^[A-Za-z0-9@%^*_+=.,:;!?~-]{8,64}$")
DUR_RE = re.compile(r"^([0-9]+[hdwm]|[0-9]{4}-[0-9]{2}-[0-9]{2}|never|0)$", re.ASCII)
REL_DUR_RE = re.compile(r"^[0-9]+[hdwm]$", re.ASCII)
OWNER_RE = re.compile(r"^[^|\r\n]{1,60}$")
IMAGES = ("ubuntu24", "ubuntu22", "ubuntu20", "debian12", "debian11", "alma9", "rocky9", "alpine")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PASS_LINE_RE = re.compile(r"(?im)^(.*password[^:\n]*:\s*).*$")
SETTING_KEYS = {
    "grace": "GRACE_DAYS",
    "shared-suspend-minutes": "SHARED_SUSPEND_MINUTES",
    "shared-threshold": "SHARED_RESOURCE_THRESHOLD",
    "monitor-interval": "RESOURCE_SAMPLE_SECONDS",
    "bandwidth-default-quota": "BANDWIDTH_DEFAULT_QUOTA_GB",
    "bandwidth-default-rate": "BANDWIDTH_DEFAULT_RATE_MBIT",
}
NUM_RE = re.compile(r"^\d+(\.\d+)?$")


class ApiError(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status
        self.msg = msg


# ---------- config ----------
_conf_lock = threading.Lock()
_conf_cache = {"mtime": None, "data": {}}


def conf():
    try:
        mtime = os.stat(CONF).st_mtime_ns
    except OSError:
        return {}
    with _conf_lock:
        if mtime != _conf_cache["mtime"]:
            data = {}
            try:
                with open(CONF, encoding="utf-8") as f:
                    for raw in f:
                        line = raw.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        data[k.strip()] = v.strip()
            except OSError:
                pass
            _conf_cache.update(mtime=mtime, data=data)
        return _conf_cache["data"]


# ---------- database ----------
COLS = (
    "name ip ssh cpu ram disk ports password created backend expires owner suspended plan "
    "quota rx tx rate quota_susp high_since cpu_prev sample_ts bw_prev_rx bw_prev_tx reason"
).split()
INTS = ("ssh", "cpu", "ram", "disk", "expires", "suspended", "quota", "rx", "tx", "quota_susp")


def to_int(v):
    """Strict integer parser for config/database fields; never truncates floats."""
    if type(v) is int:
        return v
    if isinstance(v, str):
        raw = v.strip()
        if re.fullmatch(r"-?[0-9]{1,18}", raw, flags=re.ASCII):
            try:
                return int(raw, 10)
            except (ValueError, OverflowError):
                return 0
    return 0


def read_db():
    try:
        with open(DB, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        if not line.strip():
            continue
        p = line.split("|")
        p += [""] * (len(COLS) - len(p))
        r = dict(zip(COLS, p))
        for k in INTS:
            r[k] = to_int(r[k])
        try:
            rate = float(r["rate"] or 0)
            r["rate"] = rate if __import__("math").isfinite(rate) and abs(rate) <= 100000 else 0.0
        except (ValueError, TypeError, OverflowError):
            r["rate"] = 0.0
        r["backend"] = r["backend"] or "container"
        r["plan"] = r["plan"] or "shared"
        r["reason"] = r["reason"] or "-"
        rows.append(r)
    return rows


def get_row(name):
    for r in read_db():
        if r["name"] == name:
            return r
    return None


def need_row(name):
    r = get_row(name)
    if not r:
        raise ApiError(404, "VPS tidak ditemukan.")
    return r


def pw_fp(password):
    return hashlib.sha256(password.encode()).hexdigest()


# ---------- process helpers ----------
def run_proc(argv, env=None, timeout=900):
    """Run the CLI in its own process group so a timeout also terminates descendants."""
    base = {
        "PATH": os.environ.get("PATH", "/usr/sbin:/usr/bin:/sbin:/bin") + ":/snap/bin",
        "HOME": os.environ.get("HOME", "/root"),
        "LANG": "C.UTF-8",
    }
    if env:
        base.update({k: str(v) for k, v in env.items()})
    try:
        p = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=base, start_new_session=True,
        )
        try:
            out, _ = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                out, _ = p.communicate(timeout=3)
            except subprocess.TimeoutExpired as timeout_exc:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                # Do not wait forever if a detached descendant escaped the group
                # while keeping the stdout pipe open.
                try:
                    out, _ = p.communicate(timeout=2)
                except subprocess.TimeoutExpired as final_exc:
                    out = final_exc.output or timeout_exc.output or b""
                    if p.stdout:
                        try:
                            p.stdout.close()
                        except OSError:
                            pass
                    try:
                        p.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait(timeout=2)
            tail = (out or b"").decode(errors="replace")
            return 124, "Timeout: seluruh process group dihentikan.\n" + tail
    except OSError as exc:
        return 127, f"Perintah tidak dapat dijalankan: {exc}"
    return p.returncode, out.decode(errors="replace")


def clean(out, limit=6000):
    text = ANSI_RE.sub("", out or "")
    text = PASS_LINE_RE.sub(lambda m: m.group(1) + "********", text).strip()
    return text if len(text) <= limit else "…" + text[-limit:]


def cli(args, env=None, yes=False, timeout=900):
    e = {"VPSNAT_NONINTERACTIVE": "1"}
    if yes:
        e["VPSNAT_YES"] = "1"
    if env:
        e.update(env)
    rc, out = run_proc([CLI, *args], e, timeout)
    return rc, clean(out)


def last_error(out):
    lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
    errs = [ln for ln in lines if ln.startswith("[x]")]
    if errs:
        return errs[-1][3:].strip()
    return lines[-1] if lines else "Perintah gagal."


def result(rc, out):
    if rc != 0:
        raise ApiError(400, last_error(out))
    return {"ok": True, "output": out}


# ---------- validation ----------
def v_name(v):
    v = str(v or "")
    if not isinstance(v, str) or not NAME_RE.fullmatch(v):
        raise ApiError(422, "Nama tidak valid (a-z, 0-9, -; maks 31 karakter).")
    return v


def v_int(b, key, default, lo, hi):
    v = b.get(key, default)
    # JSON bool is a subclass of int in Python; floats must not be silently truncated.
    if type(v) is int:
        n = v
    elif isinstance(v, str) and re.fullmatch(r"[0-9]{1,12}", v.strip(), flags=re.ASCII):
        n = int(v.strip(), 10)
    else:
        raise ApiError(422, f"{key} harus integer tanpa pecahan.")
    if not lo <= n <= hi:
        raise ApiError(422, f"{key} harus {lo}-{hi}.")
    return n


def v_num(v, key, hi):
    if type(v) not in (int, float, str):
        raise ApiError(422, f"{key} harus angka 0-{hi}.")
    s = str(v).strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", s, flags=re.ASCII):
        raise ApiError(422, f"{key} harus angka 0-{hi}.")
    try:
        n = float(s)
    except (ValueError, OverflowError):
        raise ApiError(422, f"{key} harus angka 0-{hi}.")
    if not __import__("math").isfinite(n) or n > hi:
        raise ApiError(422, f"{key} harus angka 0-{hi}.")
    return s


def v_choice(v, choices, key):
    if v not in choices:
        raise ApiError(422, f"{key} harus salah satu: {', '.join(choices)}.")
    return v


def v_pass(v, required=False):
    if v in (None, ""):
        if required:
            raise ApiError(422, "Password wajib diisi.")
        return None
    if not isinstance(v, str) or not PASS_RE.fullmatch(v):
        raise ApiError(422, "Password 8-64 karakter (huruf, angka, @ % ^ * _ + = . , : ; ! ? ~ -).")
    return v


def v_dur(v, relative=False):
    if v is None:
        v = "0"
    if type(v) is int and v == 0:
        v = "0"
    if not isinstance(v, str) or len(v) > 32:
        raise ApiError(422, "Durasi harus berupa string dengan format yang didukung.")
    v = v.strip().lower()
    match = (REL_DUR_RE if relative else DUR_RE).fullmatch(v)
    if not match:
        raise ApiError(422, "Format durasi: 30d, 2w, 1m, 12h" + ("" if relative else ", YYYY-MM-DD, never."))
    if v in ("0", "never"):
        if relative:
            raise ApiError(422, "Renew memerlukan durasi positif, misalnya 30d.")
        return v
    if re.fullmatch(r"[0-9]+[hdwm]", v, flags=re.ASCII):
        num, unit = int(v[:-1]), v[-1]
        unit_seconds = {"h": 3600, "d": 86400, "w": 604800, "m": 2592000}[unit]
        if num <= 0 or num * unit_seconds > 315576000:
            raise ApiError(422, "Durasi maksimum adalah 10 tahun.")
        return v
    try:
        d = datetime.datetime.strptime(v, "%Y-%m-%d").date()
    except (ValueError, TypeError):
        raise ApiError(422, "Tanggal expiry tidak valid (gunakan YYYY-MM-DD).")
    if relative:
        raise ApiError(422, "Renew hanya menerima durasi relatif.")
    if d > (datetime.date.today() + datetime.timedelta(days=3653)):
        raise ApiError(422, "Tanggal expiry maksimum 10 tahun dari hari ini.")
    return v


def v_owner(v):
    if v in (None, ""):
        v = "-"
    if not isinstance(v, str):
        raise ApiError(422, "Owner harus berupa teks.")
    v = v.strip()
    if not OWNER_RE.fullmatch(v):
        raise ApiError(422, "Owner maks 60 karakter tanpa |.")
    return v


# ---------- sessions & rate limit ----------
SESSIONS = {}
_sess_lock = threading.Lock()


def new_session(role, name=None, fp=None):
    hours = max(1, to_int(conf().get("WEB_SESSION_HOURS")) or 12)
    token = secrets.token_urlsafe(32)
    now = time.time()
    with _sess_lock:
        for k in [k for k, s in SESSIONS.items() if s["exp"] < now]:
            del SESSIONS[k]
        SESSIONS[token] = {"role": role, "name": name, "fp": fp, "exp": now + hours * 3600}
    return token, hours * 3600


def get_session(token):
    with _sess_lock:
        s = SESSIONS.get(token)
        if s and s["exp"] < time.time():
            del SESSIONS[token]
            return None
        return dict(s) if s else None


def drop_session(token):
    with _sess_lock:
        SESSIONS.pop(token, None)


def refresh_sessions(name, keep_token=None):
    row = get_row(name)
    with _sess_lock:
        for t in [t for t, s in SESSIONS.items() if s["role"] == "user" and s["name"] == name and t != keep_token]:
            del SESSIONS[t]
        if keep_token and keep_token in SESSIONS and row:
            SESSIONS[keep_token]["fp"] = pw_fp(row["password"])


WINDOW = 900
_fails = {}
_fail_lock = threading.Lock()


def blocked(key, limit):
    now = time.time()
    with _fail_lock:
        hits = [t for t in _fails.get(key, []) if now - t < WINDOW]
        if hits:
            _fails[key] = hits
        else:
            _fails.pop(key, None)
        if len(hits) >= limit:
            return int(WINDOW - (now - hits[0])) + 1
    return 0


def fail(*keys):
    now = time.time()
    with _fail_lock:
        if len(_fails) > 10000:
            _fails.clear()
        for k in keys:
            _fails.setdefault(k, []).append(now)


def throttle(ip, ident=None):
    wait = blocked(f"ip:{ip}", 5)
    if ident:
        wait = max(wait, blocked(f"id:{ident}", 20))
    if wait:
        raise ApiError(429, f"Terlalu banyak percobaan gagal. Coba lagi dalam {wait} detik.")


# ---------- locks & jobs ----------
_locks = {}
_locks_guard = threading.Lock()
ALLOC = "__alloc__"


def get_lock(key):
    with _locks_guard:
        return _locks.setdefault(key, threading.Lock())


@contextmanager
def held(*keys):
    acquired = []
    try:
        for k in sorted(set(keys)):
            lk = get_lock(k)
            lk.acquire()
            acquired.append(lk)
        yield
    finally:
        for lk in reversed(acquired):
            lk.release()


JOBS = {}
_jobs_lock = threading.Lock()
JOB_STATE_FILE = os.environ.get("VPSNAT_WEB_JOBS", os.path.join(os.path.dirname(os.path.abspath(DB)), "web-jobs.json"))
_JOB_FIELDS = ("id", "kind", "name", "who", "status", "rc", "output", "started", "finished")


def _persist_jobs_locked():
    """Atomically persist bounded, sanitized job metadata with private file permissions."""
    directory = os.path.dirname(os.path.abspath(JOB_STATE_FILE))
    os.makedirs(directory, mode=0o700, exist_ok=True)
    items = sorted(JOBS.values(), key=lambda j: j.get("started", 0), reverse=True)[:200]
    payload = [{k: j.get(k) for k in _JOB_FIELDS} for j in items]
    temp = f"{JOB_STATE_FILE}.tmp.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, JOB_STATE_FILE)
        os.chmod(JOB_STATE_FILE, 0o600)
        try:
            dfd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
    except Exception:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def _load_jobs():
    """Recover completed jobs; mark operations interrupted across web restarts."""
    changed = False
    try:
        with open(JOB_STATE_FILE, encoding="utf-8") as stream:
            rows = json.load(stream)
        if not isinstance(rows, list):
            return
        now = int(time.time())
        for j in rows[:200]:
            if not isinstance(j, dict) or not isinstance(j.get("id"), str):
                continue
            if not re.fullmatch(r"[0-9a-f]{12}", j["id"], flags=re.ASCII):
                continue
            if j.get("status") not in ("running", "done", "error", "interrupted"):
                continue
            item = {k: j.get(k) for k in _JOB_FIELDS}
            item["name"] = str(item.get("name") or "")[:64]
            item["kind"] = str(item.get("kind") or "unknown")[:64]
            item["who"] = str(item.get("who") or "")[:128]
            item["output"] = str(item.get("output") or "")[-6000:]
            if item["status"] == "running":
                item.update(status="interrupted", rc=124, finished=now,
                            output="Web service restart saat operasi berlangsung. Status hasil operasi tidak pasti; periksa LXD dan database sebelum mengulangi.")
                changed = True
            JOBS[item["id"]] = item
        if changed:
            with _jobs_lock:
                _persist_jobs_locked()
    except FileNotFoundError:
        return
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        # Keep serving, but log the recovery problem; never treat corrupt state as active jobs.
        sys.stderr.write("vpsnat-web: job state tidak dapat dipulihkan; periksa web-jobs.json.\n")


_load_jobs()


def busy_job(name):
    with _jobs_lock:
        for j in JOBS.values():
            if j["name"] == name and j["status"] == "running":
                return j["id"]
    return None


def ensure_idle(name):
    jid = busy_job(name)
    if jid:
        raise ApiError(409, f"VPS sedang diproses (job {jid}). Tunggu sampai selesai.")


def spawn(kind, name, who, fn, locks=(), after=None):
    job = {
        "id": secrets.token_hex(6),
        "kind": kind,
        "name": name,
        "who": who,
        "status": "running",
        "rc": None,
        "output": "",
        "started": int(time.time()),
        "finished": None,
    }
    with _jobs_lock:
        # Idle check and job reservation are a single atomic state transition.
        existing = next((j for j in JOBS.values() if j["name"] == name and j["status"] == "running"), None)
        if existing:
            raise ApiError(409, f"VPS sedang diproses (job {existing['id']}). Tunggu sampai selesai.")
        active = sum(1 for j in JOBS.values() if j["status"] == "running")
        if active >= 64:
            raise ApiError(503, "Server sedang sibuk; batas 64 job aktif tercapai. Coba lagi nanti.")
        done = sorted((j for j in JOBS.values() if j["status"] != "running"), key=lambda j: j["started"])
        for j in done[: max(0, len(done) - 150)]:
            del JOBS[j["id"]]
        JOBS[job["id"]] = job
        try:
            _persist_jobs_locked()
        except OSError as exc:
            JOBS.pop(job["id"], None)
            raise ApiError(503, "Tidak bisa menyimpan status job secara aman; operasi tidak dijalankan.") from exc

    def work():
        try:
            with held(name, *locks):
                rc, out = fn()
        except Exception as exc:
            rc, out = 1, f"Error internal: {type(exc).__name__}: operasi gagal."
        if after:
            try:
                after()
            except Exception:
                pass
        with _jobs_lock:
            job.update(status="done" if rc == 0 else "error", rc=rc, output=clean(out), finished=int(time.time()))
            try:
                _persist_jobs_locked()
            except OSError as exc:
                sys.stderr.write(f"vpsnat-web: gagal menyimpan hasil job {job['id']}: {exc!r}\n")

    thread = threading.Thread(target=work, daemon=True)
    try:
        thread.start()
    except RuntimeError as exc:
        with _jobs_lock:
            job.update(status="error", rc=1, output="Tidak bisa memulai worker thread.", finished=int(time.time()))
            try:
                _persist_jobs_locked()
            except OSError:
                pass
        raise ApiError(503, "Tidak dapat memulai worker job.") from exc
    return job_view(job)


def job_view(j):
    return {k: j[k] for k in ("id", "kind", "name", "status", "rc", "output", "started", "finished")}


# ---------- data views ----------
_pub = {"v": "", "t": 0.0}


def public_ip():
    v = conf().get("PUBLIC_IP", "")
    if v:
        return v
    if time.time() - _pub["t"] < 300 and _pub["v"]:
        return _pub["v"]
    rc, out = run_proc(["ip", "-4", "route", "get", "1.1.1.1"], timeout=5)
    m = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)", out) if rc == 0 else None
    _pub.update(v=m.group(1) if m else "", t=time.time())
    return _pub["v"]


_st = {"t": 0.0, "v": {}}
_st_lock = threading.Lock()


def lxc_states():
    with _st_lock:
        if time.time() - _st["t"] < 3:
            return _st["v"]
        rc, out = run_proc([LXC, "list", "--format", "csv", "-c", "ns"], timeout=20)
        states = {}
        if rc == 0:
            for line in out.splitlines():
                parts = line.strip().split(",")
                if len(parts) >= 2:
                    states[parts[0]] = parts[1].upper()
        _st.update(t=time.time(), v=states)
        return states


def invalidate_states():
    with _st_lock:
        _st["t"] = 0.0


def group_ports(raw, ssh):
    grouped = {}
    order = []
    for e in (raw or "").split(","):
        p = e.split(":")
        if len(p) != 3:
            continue
        key = (to_int(p[1]), to_int(p[2]))
        if key not in grouped:
            grouped[key] = []
            order.append(key)
        grouped[key].append(p[0])
    return [
        {"public": k[0], "internal": k[1], "proto": "+".join(grouped[k]), "ssh": k[0] == ssh} for k in order
    ]


def vps_view(r, states, admin=False, secret=False):
    used = r["rx"] + r["tx"]
    v = {
        "name": r["name"],
        "state": states.get(r["name"], "MISSING"),
        "suspended": r["suspended"] == 1,
        "reason": r["reason"],
        "plan": r["plan"],
        "backend": r["backend"],
        "cpu": r["cpu"],
        "ram": r["ram"],
        "disk": r["disk"],
        "created": r["created"],
        "expires": r["expires"],
        "host": public_ip(),
        "ssh": r["ssh"],
        "ports": group_ports(r["ports"], r["ssh"]),
        "bw": {
            "used": used,
            "rx": r["rx"],
            "tx": r["tx"],
            "quota": r["quota"],
            "rate": r["rate"],
            "exhausted": r["quota_susp"] == 1,
        },
    }
    if admin:
        v["ip"] = r["ip"]
        v["owner"] = r["owner"]
    if secret:
        v["password"] = r["password"]
    return v


_res_prev = {}
_res_lock = threading.Lock()


def resources(r):
    name = r["name"]
    rc, out = run_proc([LXC, "query", f"/1.0/instances/{name}/state"], timeout=15)
    try:
        st = json.loads(out) if rc == 0 else {}
    except ValueError:
        st = {}
    status = str(st.get("status", "")).upper() or "UNKNOWN"
    running = status == "RUNNING"
    cpu_ns = to_int((st.get("cpu") or {}).get("usage")) if running else 0
    mem = to_int((st.get("memory") or {}).get("usage")) if running else 0
    root = ((st.get("disk") or {}).get("root") or {}).get("usage")
    eth = (((st.get("network") or {}).get("eth0") or {}).get("counters")) or {}
    now = time.time()
    pct = None
    with _res_lock:
        prev = _res_prev.get(name)
        if running and prev and cpu_ns >= prev[1] and now - prev[0] >= 2:
            cores = max(1, r["cpu"])
            pct = min(100.0, max(0.0, (cpu_ns - prev[1]) / ((now - prev[0]) * 1e9 * cores) * 100))
            _res_prev[name] = (now, cpu_ns, pct)
        elif running and prev and now - prev[0] < 2:
            pct = prev[2]
        elif running:
            _res_prev[name] = (now, cpu_ns, None)
        else:
            _res_prev.pop(name, None)
    ram_limit = max(1, r["ram"]) * 1_000_000
    disk_limit = max(1, r["disk"]) * 1_000_000_000
    return {
        "state": status,
        "cpu": {"pct": None if pct is None else round(pct, 1), "cores": r["cpu"]},
        "ram": {"used": mem, "limit": ram_limit, "pct": round(min(100.0, mem / ram_limit * 100), 1)},
        "disk": {
            "used": to_int(root) if root is not None else None,
            "limit": disk_limit,
            "pct": None if root is None else round(min(100.0, to_int(root) / disk_limit * 100), 1),
        },
        "net": {"rx": to_int(eth.get("bytes_received")), "tx": to_int(eth.get("bytes_sent"))},
        "procs": to_int(st.get("processes")) if running else 0,
        "bw": {
            "used": r["rx"] + r["tx"],
            "quota": r["quota"],
            "rate": r["rate"],
            "exhausted": r["quota_susp"] == 1,
        },
    }


def host_info():
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                mem[k] = to_int(v.split()[0]) * 1024 if v.split() else 0
    except OSError:
        pass
    try:
        with open("/proc/uptime") as f:
            up = int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        up = 0
    du = shutil.disk_usage("/")
    rows = read_db()
    states = lxc_states()
    c = conf()
    return {
        "public_ip": public_ip(),
        "web": {"domain": c.get("WEB_DOMAIN", ""), "port": to_int(c.get("WEB_PORT")) or 8787, "bind": c.get("WEB_BIND") or "0.0.0.0"},
        "cores": os.cpu_count() or 0,
        "load": [round(x, 2) for x in os.getloadavg()],
        "ram": {"total": mem.get("MemTotal", 0), "avail": mem.get("MemAvailable", 0)},
        "disk": {"total": du.total, "used": du.used},
        "uptime": up,
        "vps": {
            "total": len(rows),
            "running": sum(1 for r in rows if states.get(r["name"]) == "RUNNING"),
            "suspended": sum(1 for r in rows if r["suspended"] == 1),
        },
    }


# ---------- request / routing ----------
class Req:
    def __init__(self, handler, body, auth, ip):
        self.h = handler
        self.body = body
        self.auth = auth
        self.ip = ip
        self.set_cookie = None
        self.clear_cookie = False

    @property
    def who(self):
        return "admin" if self.auth and self.auth["role"] == "admin" else (self.auth or {}).get("name", "-")


ROUTES = []


def route(method, pattern, role=None):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), role, fn))
        return fn

    return deco


# Nama VPS baru dibatasi ketat oleh v_name(); route menerima nama lebih longgar agar VPS hasil
# `sync`/import (huruf besar, titik, underscore) tetap bisa dibuka. Keberadaan nama tetap dicek ke DB.
NAME = r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]{0,62})"
PORTS_MIN, PORTS_MAX = 2, 50  # total port saat membuat VPS (termasuk 1 port SSH); samakan dengan VPS_PORTS_MAX di core.sh


# ----- auth -----
@route("POST", "/api/login/admin")
def login_admin(req):
    b = req.body
    throttle(req.ip)
    c = conf()
    stored = c.get("WEB_ADMIN_HASH", "")
    if not stored:
        raise ApiError(503, "Admin belum dikonfigurasi. Jalankan: vpsnat web-setup")
    user_ok = hmac.compare_digest(str(b.get("username", "")).encode(), c.get("WEB_ADMIN_USER", "admin").encode())
    pw_ok = verify_password(str(b.get("password", ""))[:200], stored if user_ok else DUMMY_HASH)
    if not (user_ok and pw_ok):
        fail(f"ip:{req.ip}")
        raise ApiError(401, "Username atau password salah.")
    token, ttl = new_session("admin")
    req.set_cookie = (token, ttl)
    return {"ok": True, "role": "admin"}


@route("POST", "/api/login/user")
def login_user(req):
    b = req.body
    ident = str(b.get("identifier", "")).strip().lower()[:64]
    throttle(req.ip, ident)
    password = str(b.get("password", ""))[:200]
    row = None
    for r in read_db():
        if r["name"] == ident or (ident.isascii() and ident.isdigit() and r["ssh"] == int(ident)):
            row = r
            break
    # VPS hasil `sync` memakai password placeholder "unknown"; password kosong/placeholder tidak boleh bisa login.
    usable = row is not None and row["password"] not in ("", "-", "unknown")
    expected = row["password"] if usable else "x" * 16
    ok = usable and bool(password) and hmac.compare_digest(password.encode(), expected.encode())
    if not ok:
        fail(f"ip:{req.ip}", f"id:{ident}")
        raise ApiError(401, "VPS atau password salah.")
    token, ttl = new_session("user", row["name"], pw_fp(row["password"]))
    req.set_cookie = (token, ttl)
    return {"ok": True, "role": "user", "name": row["name"]}


@route("POST", "/api/logout")
def logout(req):
    tok = req.h.session_token()
    if tok:
        drop_session(tok)
    req.clear_cookie = True
    return {"ok": True}


def branding():
    c = conf()
    logo = c.get("WEB_LOGO_URL", "")
    return {"brand": (c.get("WEB_BRAND") or "VPSNAT")[:40], "logo": logo if logo.startswith("https://") else ""}


@route("GET", "/api/session")
def session_info(req):
    base = {"ok": True, **branding()}
    if not req.auth:
        return {**base, "role": None}
    return {**base, "role": req.auth["role"], "name": req.auth.get("name")}


# ----- shared ops -----
def power_action(name, act):
    ensure_idle(name)
    with held(name):
        rc, out = cli([act, name])
    invalidate_states()
    return result(rc, out)


def change_password(name, password):
    ensure_idle(name)
    with held(name):
        rc, out = cli(["passwd", name], {"PASS": password} if password else None)
    row = get_row(name)
    resp = result(rc, out)
    resp["password"] = row["password"] if row else None
    return resp


def do_reinstall(req, name, image):
    token = req.h.session_token() if req.auth["role"] == "user" else None

    def after():
        if token:
            refresh_sessions(name, token)

    job = spawn(
        "reinstall",
        name,
        req.who,
        lambda: cli(["reinstall", name], {"IMG_KEY": image}, yes=True, timeout=1800),
        after=after,
    )
    return 202, {"ok": True, "job": job["id"]}


# ----- user routes -----
@route("GET", "/api/me", "user")
def me(req):
    r = need_row(req.auth["name"])
    return {"ok": True, "vps": vps_view(r, lxc_states(), secret=True)}


@route("GET", "/api/me/resources", "user")
def me_resources(req):
    return {"ok": True, "res": resources(need_row(req.auth["name"]))}


@route("POST", "/api/me/action", "user")
def me_action(req):
    name = req.auth["name"]
    need_row(name)
    act = v_choice(req.body.get("action"), ("start", "stop", "restart"), "action")
    return power_action(name, act)


@route("POST", "/api/me/passwd", "user")
def me_passwd(req):
    name = req.auth["name"]
    need_row(name)
    resp = change_password(name, v_pass(req.body.get("password")))
    refresh_sessions(name, req.h.session_token())
    return resp


@route("POST", "/api/me/reinstall", "user")
def me_reinstall(req):
    # Ubah OS oleh buyer dinonaktifkan; hanya admin yang boleh (POST /api/admin/vps/{name}/reinstall).
    raise ApiError(403, "Ubah OS dinonaktifkan. Hubungi admin.")


@route("GET", r"/api/me/jobs/(?P<jid>[0-9a-f]{12})", "user")
def me_job(req, jid):
    j = JOBS.get(jid)
    if not j or j["who"] != req.auth["name"]:
        raise ApiError(404, "Job tidak ditemukan.")
    if j["status"] != "running":
        refresh_sessions(req.auth["name"], req.h.session_token())
    return {"ok": True, "job": job_view(j)}


# ----- admin routes -----
@route("GET", "/api/admin/host", "admin")
def a_host(req):
    return {"ok": True, "host": host_info()}


@route("GET", "/api/admin/vps", "admin")
def a_list(req):
    states = lxc_states()
    return {
        "ok": True,
        "vps": [vps_view(r, states, admin=True) for r in read_db()],
        "limits": {"ports_min": PORTS_MIN, "ports_max": PORTS_MAX},
    }


@route("GET", rf"/api/admin/vps/{NAME}", "admin")
def a_get(req, name):
    r = need_row(name)
    return {"ok": True, "vps": vps_view(r, lxc_states(), admin=True, secret=True)}


@route("GET", rf"/api/admin/vps/{NAME}/resources", "admin")
def a_resources(req, name):
    return {"ok": True, "res": resources(need_row(name))}


@route("POST", "/api/admin/vps", "admin")
def a_create(req):
    b = req.body
    name = v_name(b.get("name"))
    if get_row(name):
        raise ApiError(409, "VPS sudah ada.")
    nesting = b.get("nesting", True)
    if type(nesting) is not bool:
        raise ApiError(422, "nesting harus boolean true/false.")
    env = {
        "NAME": name,
        "IMG_KEY": v_choice(b.get("image", "ubuntu22"), IMAGES, "image"),
        "CPU": v_int(b, "cpu", 1, 1, 128),
        "RAM": v_int(b, "ram", 1024, 128, 1048576),
        "DISK": v_int(b, "disk", 10, 1, 10000),
        "NPORTS": v_int(b, "ports", 3, PORTS_MIN, PORTS_MAX),
        "PLAN_TYPE": v_choice(b.get("plan", "shared"), ("shared", "dedicated"), "plan"),
        "VTYPE": "2" if v_choice(b.get("backend", "container"), ("container", "vm"), "backend") == "vm" else "1",
        "EXPIRE": v_dur(b.get("expire", "0")),
        "OWNER": v_owner(b.get("owner")),
        "NESTING": "y" if nesting else "n",
    }
    pw = v_pass(b.get("password"))
    if pw:
        env["PASS"] = pw
    if b.get("bw_quota_gb") not in (None, ""):
        env["BW_QUOTA_GB"] = v_num(b["bw_quota_gb"], "bw_quota_gb", 1_000_000)
    if b.get("bw_rate_mbit") not in (None, ""):
        env["BW_LIMIT_MBIT"] = v_num(b["bw_rate_mbit"], "bw_rate_mbit", 100_000)
    job = spawn("create", name, req.who, lambda: cli(["create", name, str(env["NPORTS"])], env, timeout=1800), locks=(ALLOC,))
    return 202, {"ok": True, "job": job["id"]}


@route("DELETE", rf"/api/admin/vps/{NAME}", "admin")
def a_delete(req, name):
    need_row(name)
    job = spawn("delete", name, req.who, lambda: cli(["delete", name], yes=True, timeout=600), locks=(ALLOC,))
    return 202, {"ok": True, "job": job["id"]}


@route("POST", rf"/api/admin/vps/{NAME}/action", "admin")
def a_action(req, name):
    need_row(name)
    act = v_choice(req.body.get("action"), ("start", "stop", "restart", "suspend", "unsuspend"), "action")
    return power_action(name, act)


@route("POST", rf"/api/admin/vps/{NAME}/reinstall", "admin")
def a_reinstall(req, name):
    need_row(name)
    return do_reinstall(req, name, v_choice(req.body.get("image", "ubuntu22"), IMAGES, "image"))


@route("POST", rf"/api/admin/vps/{NAME}/passwd", "admin")
def a_passwd(req, name):
    need_row(name)
    return change_password(name, v_pass(req.body.get("password")))


@route("POST", rf"/api/admin/vps/{NAME}/resize", "admin")
def a_resize(req, name):
    r = need_row(name)
    b = req.body
    env = {
        "CPU": v_int(b, "cpu", r["cpu"], 1, 128),
        "RAM": v_int(b, "ram", r["ram"], 128, 1048576),
        "DISK": v_int(b, "disk", r["disk"], r["disk"], 10000),
    }
    ensure_idle(name)
    with held(name):
        rc, out = cli(["resize", name], env)
    return result(rc, out)


@route("POST", rf"/api/admin/vps/{NAME}/renew", "admin")
def a_renew(req, name):
    need_row(name)
    dur = v_dur(req.body.get("duration"), relative=True)
    ensure_idle(name)
    with held(name):
        rc, out = cli(["renew", name, dur])
    invalidate_states()
    return result(rc, out)


@route("POST", rf"/api/admin/vps/{NAME}/expire", "admin")
def a_expire(req, name):
    need_row(name)
    val = v_dur(req.body.get("value"))
    ensure_idle(name)
    with held(name):
        rc, out = cli(["set-expire", name, val])
    return result(rc, out)


@route("POST", rf"/api/admin/vps/{NAME}/owner", "admin")
def a_owner(req, name):
    need_row(name)
    owner = v_owner(req.body.get("owner"))
    with held(name):
        rc, out = cli(["set-owner", name, owner])
    return result(rc, out)


@route("POST", rf"/api/admin/vps/{NAME}/plan", "admin")
def a_plan(req, name):
    need_row(name)
    plan = v_choice(req.body.get("plan"), ("shared", "dedicated"), "plan")
    with held(name):
        rc, out = cli(["set-type", name, plan])
    return result(rc, out)


@route("POST", rf"/api/admin/vps/{NAME}/bandwidth", "admin")
def a_bandwidth(req, name):
    need_row(name)
    b = req.body
    act = v_choice(b.get("action"), ("set", "limit", "reset"), "action")
    if act == "set":
        args = ["bandwidth", name, "set", v_num(b.get("quota_gb", 0), "quota_gb", 1_000_000), v_num(b.get("rate_mbit", 0), "rate_mbit", 100_000)]
    elif act == "limit":
        args = ["bandwidth", name, "limit", v_num(b.get("rate_mbit", 0), "rate_mbit", 100_000)]
    else:
        args = ["bandwidth", name, "reset"]
    ensure_idle(name)
    with held(name):
        rc, out = cli(args)
    return result(rc, out)


@route("POST", rf"/api/admin/vps/{NAME}/ports", "admin")
def a_port_add(req, name):
    need_row(name)
    env = {
        "PROTO": v_choice(req.body.get("proto", "tcp"), ("tcp", "udp", "both"), "proto"),
        "COUNT": v_int(req.body, "count", 1, 1, 500),
    }
    ensure_idle(name)
    with held(name, ALLOC):
        rc, out = cli(["port-add", name], env)
    return result(rc, out)


@route("DELETE", rf"/api/admin/vps/{NAME}/ports/(?P<port>[^/]*)", "admin")
def a_port_del(req, name, port):
    need_row(name)
    if not (port.isascii() and port.isdigit() and 1 <= int(port) <= 65535):
        raise ApiError(422, "Port publik tidak valid (pilih port yang akan dihapus).")
    ensure_idle(name)
    with held(name, ALLOC):
        rc, out = cli(["port-del", name], {"EXT": port})
    return result(rc, out)


@route("GET", "/api/admin/settings", "admin")
def a_settings(req):
    rc, out = cli(["settings", "show"])
    vals = {}
    for line in out.splitlines():
        k, sep, v = line.partition("=")
        if sep and k.strip():
            vals[k.strip()] = v.strip()
    return {"ok": True, "settings": vals, "keys": list(SETTING_KEYS)}


@route("POST", "/api/admin/settings", "admin")
def a_settings_set(req):
    key = v_choice(req.body.get("key"), tuple(SETTING_KEYS), "key")
    val = v_num(req.body.get("value"), "value", 1_000_000)
    with held(ALLOC):
        rc, out = cli(["settings", "set", key, val])
    return result(rc, out)


@route("POST", "/api/admin/sync", "admin")
def a_sync(req):
    with held(ALLOC):
        rc, out = cli(["sync"], timeout=300)
    invalidate_states()
    return result(rc, out)


@route("GET", "/api/admin/nodes", "admin")
def a_nodes(req):
    rc, out = cli(["nodes"], timeout=120)
    return result(rc, out)


@route("GET", "/api/admin/jobs", "admin")
def a_jobs(req):
    with _jobs_lock:
        items = sorted(JOBS.values(), key=lambda j: j["started"], reverse=True)[:30]
        return {"ok": True, "jobs": [job_view(j) for j in items]}


@route("GET", r"/api/admin/jobs/(?P<jid>[0-9a-f]{12})", "admin")
def a_job(req, jid):
    with _jobs_lock:
        j = JOBS.get(jid)
        if not j:
            raise ApiError(404, "Job tidak ditemukan.")
        return {"ok": True, "job": job_view(j)}


# ---------- PWA (manifest, service worker, ikon) ----------
PWA_REV = "1"  # naikkan jika isi service worker/ikon berubah tanpa perubahan web.html
PWA_THEME = "#2563eb"
PWA_ICONS = {"/icon-192.png": 192, "/icon-512.png": 512, "/apple-touch-icon.png": 180}
PWA_PATHS = frozenset({"/manifest.webmanifest", "/sw.js", *PWA_ICONS})

# Service worker sengaja TIDAK menyentuh /api/*: sesi, password VPS, dan data resource tidak pernah
# masuk cache. Yang di-cache hanya shell HTML (tanpa data), manifest, dan ikon. HTML shell dicache
# bersama header CSP-nya, sehingga nonce di dalamnya tetap cocok saat dimuat offline.
PWA_SW = r"""'use strict';
const CACHE = 'vpsnat-%V%';
const ASSETS = ['/manifest.webmanifest', '/icon-192.png', '/icon-512.png', '/apple-touch-icon.png'];
const OFFLINE = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Offline</title><body style="margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#f8fafc;color:#0f172a;text-align:center"><div style="padding:24px"><h1 style="font-size:20px">Tidak ada koneksi</h1><p style="color:#64748b">Panel butuh koneksi ke server. Coba lagi setelah online.</p><button onclick="location.reload()" style="padding:10px 18px;border:0;border-radius:10px;background:#2563eb;color:#fff;font:inherit;font-weight:600">Muat ulang</button></div>';
self.addEventListener('install', e => e.waitUntil(
  caches.open(CACHE).then(c => c.addAll(['/'].concat(ASSETS))).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== self.location.origin || u.pathname.startsWith('/api/')) return;
  if (r.mode === 'navigate') {
    e.respondWith(fetch(r).then(res => {
      if (res.ok && u.pathname === '/') { const cp = res.clone(); e.waitUntil(caches.open(CACHE).then(c => c.put('/', cp))); }
      return res;
    }).catch(() => caches.match('/').then(m => m || new Response(OFFLINE, {status: 503, headers: {'Content-Type': 'text/html; charset=utf-8'}}))));
    return;
  }
  if (ASSETS.includes(u.pathname)) e.respondWith(caches.match(r).then(m => m || fetch(r)));
});
"""


def pwa_version():
    h = hashlib.sha256(load_ui().encode())
    h.update((PWA_REV + branding()["brand"]).encode())
    return h.hexdigest()[:10]


def pwa_manifest():
    brand = branding()["brand"]
    icon = lambda n: {"src": f"/icon-{n}.png", "sizes": f"{n}x{n}", "type": "image/png", "purpose": "any maskable"}
    return {
        "id": "/",
        "name": f"{brand} Panel",
        "short_name": brand[:12],
        "description": "Panel manajemen VPS: kontrol, resource live, dan administrasi.",
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "background_color": "#f8fafc",
        "theme_color": PWA_THEME,
        "lang": "id",
        "categories": ["utilities", "productivity"],
        "icons": [icon(192), icon(512)],
    }


def _png_chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def _sd_rrect(px, py, cx, cy, hw, hh, r):
    qx, qy = abs(px - cx) - hw + r, abs(py - cy) - hh + r
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


@functools.lru_cache(maxsize=8)
def pwa_icon(size):
    """Ikon PNG (stdlib murni): dua bar server putih di atas latar biru. Full-bleed + area aman maskable."""
    bg, fg = (37, 99, 235), (255, 255, 255)
    cx, hw, hh, rad = size / 2, size * 0.26, size * 0.085, size * 0.05
    bars = (size * 0.385, size * 0.615)
    dot_x, dot_r = cx - hw + size * 0.085, max(size * 0.024, 1.2)
    base = bytes(bg) * size
    rows = bytearray()
    for y in range(size):
        py = y + 0.5
        cy = next((c for c in bars if abs(py - c) <= hh + 2), None)
        if cy is None:
            rows += b"\x00" + base
            continue
        line = bytearray(base)
        for x in range(int(cx - hw) - 2, int(cx + hw) + 3):
            px = x + 0.5
            a = min(max(0.5 - _sd_rrect(px, py, cx, cy, hw, hh, rad), 0.0), 1.0)
            if a <= 0:
                continue
            col = [bg[i] + (fg[i] - bg[i]) * a for i in range(3)]
            b = min(max(0.5 - (math.hypot(px - dot_x, py - cy) - dot_r), 0.0), 1.0)
            if b > 0:
                col = [col[i] + (bg[i] - col[i]) * b for i in range(3)]
            line[x * 3:x * 3 + 3] = bytes(int(round(v)) for v in col)
        rows += b"\x00" + bytes(line)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + _png_chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + _png_chunk(b"IEND", b"")
    )


# ---------- HTTP server ----------
def load_ui():
    try:
        with open(os.path.join(APP_DIR, "web.html"), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return "<h1>web.html tidak ditemukan</h1>"


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """Limit request threads; reject overload instead of exhausting process memory."""
    max_workers = 64

    def __init__(self, *args, **kwargs):
        self._worker_slots = threading.BoundedSemaphore(self.max_workers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self._worker_slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\nRetry-After: 2\r\n\r\n")
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._worker_slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vpsnat-web"
    sys_version = ""
    timeout = 15

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_ip(), fmt % args))

    def client_ip(self):
        c = conf()
        remote = self.client_address[0]
        if c.get("WEB_TRUST_PROXY") == "1":
            trusted = False
            try:
                trusted = ipaddress.ip_address(remote).is_loopback
            except ValueError:
                trusted = False
            # For a non-loopback reverse proxy, require an exact explicitly trusted IP.
            trusted_ips = {item.strip() for item in (c.get("WEB_TRUST_PROXY_IPS") or "").split(",") if item.strip()}
            trusted = trusted or remote in trusted_ips
            if trusted:
                header = c.get("WEB_IP_HEADER") or "X-Forwarded-For"
                fwd = (self.headers.get(header) or "").split(",")[-1].strip()
                if fwd:
                    try:
                        return str(ipaddress.ip_address(fwd))
                    except ValueError:
                        pass
        return remote

    def is_https(self):
        return conf().get("WEB_TRUST_PROXY") == "1" and self.headers.get("X-Forwarded-Proto", "").lower() == "https"

    def session_token(self):
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        try:
            c = SimpleCookie(raw)
        except Exception:
            return None
        m = c.get(COOKIE)
        return m.value if m else None

    def authenticate(self, ip):
        authz = self.headers.get("Authorization", "")
        if authz.startswith("Bearer "):
            wait = blocked(f"key:{ip}", 10)
            if wait:
                raise ApiError(429, f"Terlalu banyak percobaan gagal. Coba lagi dalam {wait} detik.")
            key = conf().get("WEB_API_KEY", "")
            if len(key) >= 32 and hmac.compare_digest(authz[7:].strip().encode(), key.encode()):
                return {"role": "admin", "via": "key"}
            fail(f"key:{ip}")
            raise ApiError(401, "API key tidak valid.")
        tok = self.session_token()
        s = get_session(tok) if tok else None
        if not s:
            return None
        if s["role"] == "user":
            row = get_row(s["name"])
            # Reinstall mengganti password di tengah job; sesi pemilik diperbarui oleh after() saat job selesai.
            if not row or (pw_fp(row["password"]) != s["fp"] and not busy_job(s["name"])):
                drop_session(tok)
                return None
        s["via"] = "cookie"
        return s

    def security_headers(self, nonce=None):
        csp = (
            "default-src 'none'; connect-src 'self'; img-src 'self' data: https:; "
            "style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
            "manifest-src 'self'; worker-src 'self'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        )
        if nonce:
            csp += f"; script-src 'nonce-{nonce}'"
        self.send_header("Content-Security-Policy", csp)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        if self.is_https():
            self.send_header("Strict-Transport-Security", "max-age=31536000")

    def send_bytes(self, status, ctype, data, extra=None, nonce=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if self.close_connection:
            self.send_header("Connection", "close")
        self.security_headers(nonce)
        for k, v in extra or []:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status, obj, extra=None):
        self.send_bytes(status, "application/json; charset=utf-8", json.dumps(obj).encode(), extra)

    def send_pwa(self, path):
        if path == "/manifest.webmanifest":
            return self.send_bytes(200, "application/manifest+json; charset=utf-8", json.dumps(pwa_manifest()).encode())
        if path == "/sw.js":
            js = PWA_SW.replace("%V%", pwa_version()).encode()
            return self.send_bytes(200, "text/javascript; charset=utf-8", js, extra=[("Service-Worker-Allowed", "/")])
        return self.send_bytes(200, "image/png", pwa_icon(PWA_ICONS[path]))

    def read_body(self):
        # This server does not implement chunked requests. Reject ambiguous framing.
        transfer = self.headers.get_all("Transfer-Encoding", [])
        lengths = self.headers.get_all("Content-Length", [])
        if transfer:
            self.close_connection = True
            raise ApiError(400, "Transfer-Encoding tidak didukung; gunakan Content-Length.")
        if len(lengths) > 1:
            self.close_connection = True
            raise ApiError(400, "Content-Length duplikat tidak diizinkan.")
        if not lengths:
            return {}
        raw_n = lengths[0].strip()
        if not re.fullmatch(r"[0-9]{1,10}", raw_n, flags=re.ASCII):
            self.close_connection = True
            raise ApiError(400, "Content-Length tidak valid.")
        n = int(raw_n, 10)
        if n > MAX_BODY:
            self.close_connection = True
            raise ApiError(413, "Body terlalu besar.")
        if n == 0:
            self._body_read = True
            return {}
        try:
            # Use read1 + an absolute deadline so a client cannot keep a worker
            # occupied indefinitely by slowly trickling bytes under the socket timeout.
            deadline = time.monotonic() + min(float(self.timeout or 15), 15.0)
            chunks = bytearray()
            while len(chunks) < n:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("body deadline exceeded")
                self.connection.settimeout(remaining)
                part = self.rfile.read1(n - len(chunks))
                if not part:
                    break
                chunks.extend(part)
            raw = bytes(chunks)
        except (OSError, TimeoutError):
            self.close_connection = True
            raise ApiError(400, "Body request tidak lengkap atau melewati batas waktu.")
        finally:
            try:
                self.connection.settimeout(self.timeout)
            except OSError:
                pass
        if len(raw) != n:
            self.close_connection = True
            raise ApiError(400, "Body request terpotong.")
        self._body_read = True
        try:
            data = json.loads(raw, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
        except (ValueError, UnicodeDecodeError, RecursionError):
            self.close_connection = True
            raise ApiError(400, "Body harus JSON valid (NaN/Infinity dan nesting ekstrem tidak diizinkan).")
        if not isinstance(data, dict):
            raise ApiError(400, "Body harus objek JSON.")
        return data

    def handle_any(self, method):
        self._body_read = False
        if method == "GET":
            transfer = self.headers.get_all("Transfer-Encoding", [])
            lengths = self.headers.get_all("Content-Length", [])
            invalid_length = len(lengths) > 1 or any(not re.fullmatch(r"0+", item.strip(), flags=re.ASCII) for item in lengths)
            if transfer or invalid_length:
                self.close_connection = True
                return self.send_json(400, {"ok": False, "error": "GET tidak menerima body atau framing ambigu."})
        path = urlparse(self.path).path
        if method == "GET" and path == "/":
            nonce = secrets.token_urlsafe(16)
            html = load_ui().replace("{{NONCE}}", nonce).encode()
            return self.send_bytes(200, "text/html; charset=utf-8", html, nonce=nonce)
        if method == "GET" and path == "/favicon.ico":
            return self.send_bytes(204, "image/x-icon", b"")
        if method == "GET" and path in PWA_PATHS:
            return self.send_pwa(path)
        if not path.startswith("/api/"):
            return self.send_json(404, {"ok": False, "error": "Not found."})
        ip = self.client_ip()
        try:
            handler = None
            for m, rx, role, fn in ROUTES:
                if m != method:
                    continue
                match = rx.match(path)
                if match:
                    handler = (role, fn, match.groupdict())
                    break
            if not handler:
                raise ApiError(404, f"Endpoint tidak ditemukan: {method} {path[:120]}")
            role, fn, kwargs = handler
            body = self.read_body() if method in ("POST", "DELETE") else {}
            auth = self.authenticate(ip)
            if method != "GET" and (not auth or auth.get("via") == "cookie"):
                if self.headers.get("X-Requested-With") != "vpsnat":
                    raise ApiError(403, "Header X-Requested-With wajib.")
            if role and (not auth or auth["role"] != role):
                raise ApiError(401 if not auth else 403, "Tidak diizinkan.")
            req = Req(self, body, auth, ip)
            res = fn(req, **kwargs)
            status, payload = res if isinstance(res, tuple) else (200, res)
            extra = []
            if req.set_cookie:
                tok, ttl = req.set_cookie
                flags = "; HttpOnly; SameSite=Strict; Path=/" + ("; Secure" if self.is_https() else "")
                extra.append(("Set-Cookie", f"{COOKIE}={tok}; Max-Age={ttl}{flags}"))
            if req.clear_cookie:
                extra.append(("Set-Cookie", f"{COOKIE}=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/"))
            self.send_json(status, payload, extra)
        except ApiError as exc:
            lengths = self.headers.get_all("Content-Length", [])
            if method in ("POST", "DELETE") and not self._body_read and lengths:
                self.close_connection = True  # sisa body belum dibaca; jangan dipakai ulang sebagai request baru
            self.send_json(exc.status, {"ok": False, "error": exc.msg})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            sys.stderr.write(f"internal error: {exc!r}\n")
            self.send_json(500, {"ok": False, "error": "Kesalahan internal."})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    c = conf()
    bind = c.get("WEB_BIND") or "0.0.0.0"
    port = to_int(c.get("WEB_PORT")) or 8787
    if not c.get("WEB_ADMIN_HASH"):
        sys.stderr.write("PERINGATAN: WEB_ADMIN_HASH belum diset (vpsnat web-setup).\n")
    srv = BoundedThreadingHTTPServer((bind, port), Handler)
    srv.daemon_threads = True
    sys.stderr.write(f"vpsnat-web listen {bind}:{port}\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
