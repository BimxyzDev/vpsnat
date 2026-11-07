#!/usr/bin/env python3
"""VPSNAT Node Agent — data-plane daemon (padanan `wings` Pterodactyl).

Agent berjalan di setiap NODE dan bertanggung jawab atas seluruh proses VPS
client: LXD (container/VM), NAT/port forwarding, bandwidth shaping, hardening,
suspend otomatis, dan expiry. Panel hanya mengirim perintah dan menerima hasil.

Desain penting:
  * Panel adalah satu-satunya pihak yang memulai koneksi (panel → agent), jadi
    node tidak butuh akses masuk ke panel dan tidak ada port panel yang dibuka.
  * Alokasi port milik PANEL. Panel mengirim daftar port eksplisit; node hanya
    memasang DNAT. Ini mencegah dua client memakai port yang sama.
  * Semua operasi provisioning tetap dijalankan oleh CLI Bash `vpsnat`, jadi
    perilaku CLI dan panel tidak pernah menyimpang.
  * Operasi panjang (create/delete/reinstall) berjalan sebagai job yang bisa
    dipoll, sehingga koneksi HTTP tidak perlu menunggu provisioning selesai.

Jalankan: systemctl status vpsnat-node   (unit: vpsnat-node.service)
Token   : vpsnat node token   → /etc/vpsnat/node.json
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, urlparse

VERSION = "4.0.0"
AGENT_PREFIX = "/api/v1"

CONF = os.environ.get("VPSNAT_NODE_CONF", "/etc/vpsnat/vpsnat.conf")
NODE_DB = os.environ.get("VPSNAT_NODE_DB", "/etc/vpsnat/vps.db")
IDENTITY = os.environ.get("VPSNAT_NODE_IDENTITY", "/etc/vpsnat/node.json")
JOBS_FILE = os.environ.get("VPSNAT_NODE_JOBS", "/etc/vpsnat/node-jobs.json")
CLI = os.environ.get("VPSNAT_NODE_CLI", "/usr/local/bin/vpsnat")
LXC = os.environ.get("VPSNAT_NODE_LXC") or shutil.which("lxc", path=os.environ.get("PATH", "") + ":/snap/bin") or "/snap/bin/lxc"

MAX_BODY = 262144
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
PASS_RE = re.compile(r"^[A-Za-z0-9@%^*_+=.,:;!?~-]{8,64}$")
DUR_RE = re.compile(r"^([0-9]+[hdwm]|[0-9]{4}-[0-9]{2}-[0-9]{2}|never|0)$", re.ASCII)
REL_DUR_RE = re.compile(r"^[0-9]+[hdwm]$", re.ASCII)
OWNER_RE = re.compile(r"^[^|\r\n]{1,60}$")
IMAGES = ("ubuntu24", "ubuntu22", "ubuntu20", "debian12", "debian11", "alma9", "rocky9", "alpine")

COLS = (
    "name ip ssh cpu ram disk ports password created backend expires owner suspended plan "
    "quota rx tx rate quota_susp high_since cpu_prev sample_ts bw_prev_rx bw_prev_tx reason"
).split()
INTS = ("ssh", "cpu", "ram", "disk", "expires", "suspended", "quota", "rx", "tx", "quota_susp")


# --------------------------------------------------------------------------- utils
def conf() -> dict:
    data: dict[str, str] = {}
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
    return data


def to_int(value) -> int:
    if type(value) is int:
        return value
    if isinstance(value, str) and re.fullmatch(r"-?[0-9]{1,18}", value.strip(), flags=re.ASCII):
        with contextlib.suppress(ValueError):
            return int(value.strip(), 10)
    return 0


class AgentError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(msg)
        self.status = status
        self.msg = msg


# --------------------------------------------------------------------------- identity
def load_identity() -> dict:
    try:
        with open(IDENTITY, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {}


def save_identity(data: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(IDENTITY)), mode=0o700, exist_ok=True)
    tmp = f"{IDENTITY}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, IDENTITY)
    os.chmod(IDENTITY, 0o600)


def agent_token() -> str:
    token = os.environ.get("VPSNAT_NODE_TOKEN", "") or conf().get("NODE_TOKEN", "")
    if token:
        return token
    return str(load_identity().get("token") or "")


# --------------------------------------------------------------------------- process
def run_proc(argv, env=None, timeout=900):
    base = {
        "PATH": os.environ.get("PATH", "/usr/sbin:/usr/bin:/sbin:/bin") + ":/snap/bin",
        "HOME": os.environ.get("HOME", "/root"),
        "LANG": "C.UTF-8",
        "VPSNAT_NONINTERACTIVE": "1",
    }
    if env:
        base.update({k: str(v) for k, v in env.items()})
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=base, start_new_session=True,
        )
    except OSError as exc:
        return 127, f"Perintah tidak dapat dijalankan: {exc}"
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                out, _ = proc.communicate(timeout=3)
            if not isinstance(out, (bytes, bytearray)):
                out = b""
        return 124, "Timeout: process group dihentikan.\n" + (out or b"").decode(errors="replace")
    return proc.returncode, (out or b"").decode(errors="replace")


ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PASS_LINE_RE = re.compile(r"(?im)^(.*password[^:\n]*:\s*).*$")


def clean(text: str, limit: int = 6000) -> str:
    out = ANSI_RE.sub("", text or "")
    out = PASS_LINE_RE.sub(lambda m: m.group(1) + "********", out).strip()
    return out if len(out) <= limit else "…" + out[-limit:]


def cli(args, env=None, yes=False, timeout=900):
    extra = {"VPSNAT_YES": "1"} if yes else {}
    if env:
        extra.update(env)
    rc, out = run_proc([CLI, *args], extra, timeout)
    return rc, clean(out)


def last_error(out: str) -> str:
    lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
    errs = [ln for ln in lines if ln.startswith("[x]")]
    if errs:
        return errs[-1][3:].strip()
    return lines[-1] if lines else "Perintah gagal."


# --------------------------------------------------------------------------- node db
def read_db() -> list[dict]:
    try:
        with open(NODE_DB, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("|")
        parts += [""] * (len(COLS) - len(parts))
        row = dict(zip(COLS, parts))
        for k in INTS:
            row[k] = to_int(row[k])
        with contextlib.suppress(TypeError, ValueError):
            row["rate"] = float(row["rate"] or 0)
        row["backend"] = row["backend"] or "container"
        row["plan"] = row["plan"] or "shared"
        row["reason"] = row["reason"] or "-"
        rows.append(row)
    return rows


def get_row(name: str) -> dict | None:
    for row in read_db():
        if row["name"] == name:
            return row
    return None


def need_row(name: str) -> dict:
    if not SAFE_NAME_RE.fullmatch(name or ""):
        raise AgentError(404, "Instance tidak ditemukan.")
    row = get_row(name)
    if not row:
        raise AgentError(404, "Instance tidak ditemukan di node ini.")
    return row


# --------------------------------------------------------------------------- lxd
_states_cache = {"t": 0.0, "v": {}}
_states_lock = threading.Lock()


def lxc_states() -> dict:
    with _states_lock:
        if time.time() - _states_cache["t"] < 3:
            return dict(_states_cache["v"])
    rc, out = run_proc([LXC, "list", "--format", "csv", "-c", "ns"], timeout=20)
    states = {}
    if rc == 0:
        for line in out.splitlines():
            parts = line.strip().split(",")
            if len(parts) >= 2:
                states[parts[0]] = parts[1].upper()
    with _states_lock:
        _states_cache.update(t=time.time(), v=states)
    return states


_res_cache: dict[str, tuple] = {}
_res_prev: dict[str, tuple] = {}
_res_lock = threading.Lock()


def instance_resources(row: dict) -> dict:
    name = row["name"]
    if not SAFE_NAME_RE.fullmatch(name):
        raise AgentError(404, "Nama instance tidak valid.")
    with _res_lock:
        hit = _res_cache.get(name)
        if hit and time.monotonic() - hit[0] < 2:
            return hit[1]
    rc, out = run_proc([LXC, "query", f"/1.0/instances/{quote(name, safe='')}/state"], timeout=15)
    state = {}
    if rc == 0:
        with contextlib.suppress(ValueError):
            parsed = json.loads(out)
            if isinstance(parsed, dict):
                state = parsed
    status = str(state.get("status", "")).upper() or lxc_states().get(name, "UNKNOWN")
    running = status == "RUNNING"
    cpu_ns = to_int((state.get("cpu") or {}).get("usage")) if running else 0
    mem = to_int((state.get("memory") or {}).get("usage")) if running else 0
    root = ((state.get("disk") or {}).get("root") or {}).get("usage")
    eth = (((state.get("network") or {}).get("eth0") or {}).get("counters")) or {}
    now = time.time()
    pct = None
    with _res_lock:
        prev = _res_prev.get(name)
        if running and prev and cpu_ns >= prev[1] and now - prev[0] >= 2:
            cores = max(1, row["cpu"])
            pct = min(100.0, max(0.0, (cpu_ns - prev[1]) / ((now - prev[0]) * 1e9 * cores) * 100))
            _res_prev[name] = (now, cpu_ns, pct)
        elif running and prev and now - prev[0] < 2:
            pct = prev[2]
        elif running:
            _res_prev[name] = (now, cpu_ns, None)
        else:
            _res_prev.pop(name, None)
    ram_limit = max(1, row["ram"]) * 1_000_000
    disk_limit = max(1, row["disk"]) * 1_000_000_000
    res = {
        "state": status,
        "cpu": {"pct": None if pct is None else round(pct, 1), "cores": row["cpu"]},
        "ram": {"used": mem, "limit": ram_limit, "pct": round(min(100.0, mem / ram_limit * 100), 1)},
        "disk": {
            "used": to_int(root) if root is not None else None,
            "limit": disk_limit,
            "pct": None if root is None else round(min(100.0, to_int(root) / disk_limit * 100), 1),
        },
        "net": {"rx": to_int(eth.get("bytes_received")), "tx": to_int(eth.get("bytes_sent"))},
        "procs": to_int(state.get("processes")) if running else 0,
        "bw": {
            "used": row["rx"] + row["tx"],
            "rx": row["rx"],
            "tx": row["tx"],
            "quota": row["quota"],
            "rate": row["rate"],
            "exhausted": row["quota_susp"] == 1,
        },
    }
    with _res_lock:
        _res_cache[name] = (time.monotonic(), res)
    return res


def group_ports(raw: str, ssh: int) -> list[dict]:
    grouped: dict[tuple, list] = {}
    order: list[tuple] = []
    for entry in (raw or "").split(","):
        parts = entry.split(":")
        if len(parts) != 3:
            continue
        key = (to_int(parts[1]), to_int(parts[2]))
        if key not in grouped:
            grouped[key] = []
            order.append(key)
        grouped[key].append(parts[0])
    return [{"public": k[0], "internal": k[1], "proto": "+".join(grouped[k]), "ssh": k[0] == ssh} for k in order]


def public_ip() -> str:
    ip = conf().get("PUBLIC_IP", "")
    if ip:
        return ip
    rc, out = run_proc(["ip", "-4", "route", "get", "1.1.1.1"], timeout=5)
    if rc == 0:
        m = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)", out)
        if m:
            return m.group(1)
    return ""


def instance_view(row: dict, states: dict | None = None, secret: bool = False) -> dict:
    states = states if states is not None else lxc_states()
    view = {
        "name": row["name"],
        "state": states.get(row["name"], "MISSING"),
        "suspended": row["suspended"] == 1,
        "reason": row["reason"],
        "plan": row["plan"],
        "backend": row["backend"],
        "cpu": row["cpu"],
        "ram": row["ram"],
        "disk": row["disk"],
        "created": row["created"],
        "expires": row["expires"],
        "ssh": row["ssh"],
        "ports": group_ports(row["ports"], row["ssh"]),
        "bw": {
            "used": row["rx"] + row["tx"],
            "rx": row["rx"],
            "tx": row["tx"],
            "quota": row["quota"],
            "rate": row["rate"],
            "exhausted": row["quota_susp"] == 1,
        },
        "ip": row["ip"],
        "owner": row["owner"],
    }
    if secret:
        view["password"] = row["password"]
    return view


# --------------------------------------------------------------------------- jobs
JOBS: dict[str, dict] = {}
_jobs_lock = threading.Lock()
_JOB_FIELDS = ("id", "kind", "name", "status", "rc", "output", "started", "finished")


def _persist_jobs_locked() -> None:
    directory = os.path.dirname(os.path.abspath(JOBS_FILE))
    os.makedirs(directory, mode=0o700, exist_ok=True)
    items = sorted(JOBS.values(), key=lambda j: j.get("started", 0), reverse=True)[:100]
    payload = [{k: j.get(k) for k in _JOB_FIELDS} for j in items]
    tmp = f"{JOBS_FILE}.tmp.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, JOBS_FILE)
    except Exception:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def load_jobs() -> None:
    try:
        with open(JOBS_FILE, encoding="utf-8") as f:
            rows = json.load(f)
    except FileNotFoundError:
        return
    except (OSError, ValueError):
        sys.stderr.write("vpsnat-node: node-jobs.json tidak dapat dibaca\n")
        return
    if not isinstance(rows, list):
        return
    now = int(time.time())
    changed = False
    for j in rows[:100]:
        if not isinstance(j, dict) or not isinstance(j.get("id"), str):
            continue
        if not re.fullmatch(r"[0-9a-f]{12}", j["id"], flags=re.ASCII):
            continue
        item = {k: j.get(k) for k in _JOB_FIELDS}
        if item["status"] == "running":
            item.update(
                status="interrupted", rc=124, finished=now,
                output="Agent node restart saat operasi berlangsung; status hasil tidak pasti.",
            )
            changed = True
        JOBS[item["id"]] = item
    if changed:
        with _jobs_lock, contextlib.suppress(OSError):
            _persist_jobs_locked()


def busy(name: str) -> str | None:
    with _jobs_lock:
        for j in JOBS.values():
            if j["name"] == name and j["status"] == "running":
                return j["id"]
    return None


def ensure_idle(name: str) -> None:
    jid = busy(name)
    if jid:
        raise AgentError(409, f"Instance sedang diproses (job {jid}).")


def job_view(j: dict) -> dict:
    return {k: j[k] for k in _JOB_FIELDS}


def spawn(kind: str, name: str, fn) -> dict:
    job = {
        "id": secrets.token_hex(6),
        "kind": kind,
        "name": name,
        "status": "running",
        "rc": None,
        "output": "",
        "started": int(time.time()),
        "finished": None,
    }
    with _jobs_lock:
        if any(j["name"] == name and j["status"] == "running" for j in JOBS.values()):
            raise AgentError(409, "Instance sedang diproses job lain.")
        active = sum(1 for j in JOBS.values() if j["status"] == "running")
        if active >= 32:
            raise AgentError(503, "Node sibuk: batas 32 job aktif.")
        done = sorted((j for j in JOBS.values() if j["status"] != "running"), key=lambda j: j["started"])
        for j in done[: max(0, len(done) - 80)]:
            JOBS.pop(j["id"], None)
        JOBS[job["id"]] = job
        _persist_jobs_locked()

    def work():
        rc, out = 1, "Operasi tidak dijalankan."
        try:
            rc, out = fn()
        except Exception as exc:  # noqa: BLE001
            rc, out = 1, f"Error internal: {type(exc).__name__}"
        with _jobs_lock:
            job.update(status="done" if rc == 0 else "error", rc=rc, output=clean(out), finished=int(time.time()))
            with contextlib.suppress(OSError):
                _persist_jobs_locked()

    threading.Thread(target=work, daemon=True).start()
    return job_view(job)


# --------------------------------------------------------------------------- validation
def v_int(body: dict, key: str, default: int, lo: int, hi: int) -> int:
    raw = body.get(key, default)
    if type(raw) is int:
        n = raw
    elif isinstance(raw, str) and re.fullmatch(r"[0-9]{1,12}", raw.strip(), flags=re.ASCII):
        n = int(raw.strip(), 10)
    else:
        raise AgentError(422, f"{key} harus integer.")
    if not lo <= n <= hi:
        raise AgentError(422, f"{key} harus {lo}-{hi}.")
    return n


def v_num(value, key: str, hi: float) -> str:
    raw = str(value if value is not None else "0").strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", raw, flags=re.ASCII):
        raise AgentError(422, f"{key} harus angka 0-{hi}.")
    if float(raw) > hi:
        raise AgentError(422, f"{key} maksimum {hi}.")
    return raw


def v_choice(value, choices, key: str):
    if value not in choices:
        raise AgentError(422, f"{key} harus salah satu: {', '.join(choices)}.")
    return value


def v_pass(value, required: bool = False):
    if value in (None, ""):
        if required:
            raise AgentError(422, "Password wajib.")
        return None
    if not isinstance(value, str) or not PASS_RE.fullmatch(value):
        raise AgentError(422, "Password 8-64 karakter (huruf, angka, simbol aman).")
    return value


def v_dur(value, relative: bool = False) -> str:
    if value is None:
        value = "0"
    if type(value) is int and value == 0:
        value = "0"
    if not isinstance(value, str) or len(value) > 32:
        raise AgentError(422, "Durasi tidak valid.")
    value = value.strip().lower()
    if not (REL_DUR_RE if relative else DUR_RE).fullmatch(value):
        raise AgentError(422, "Format durasi: 30d, 2w, 1m, 12h" + ("" if relative else ", YYYY-MM-DD, never."))
    if value in ("0", "never") and relative:
        raise AgentError(422, "Butuh durasi positif.")
    return value


def v_owner(value) -> str:
    if value in (None, ""):
        return "-"
    if not isinstance(value, str):
        raise AgentError(422, "Owner harus teks.")
    value = value.strip()
    if not OWNER_RE.fullmatch(value):
        raise AgentError(422, "Owner maks 60 karakter tanpa |.")
    return value


# --------------------------------------------------------------------------- operations
def op_create(body: dict) -> tuple[int, str]:
    name = str(body.get("name") or "")
    if not NAME_RE.fullmatch(name):
        raise AgentError(422, "Nama tidak valid (a-z, 0-9, -; maks 31).")
    if get_row(name):
        raise AgentError(409, "Instance sudah ada di node ini.")
    if any(r["name"] == name for r in read_db()):
        raise AgentError(409, "Nama sudah dipakai.")
    ports = body.get("ports")
    if not isinstance(ports, list) or not ports:
        raise AgentError(422, "ports wajib: daftar port publik dari panel.")
    cleaned: list[str] = []
    for item in ports:
        raw = item.get("public") if isinstance(item, dict) else item
        if type(raw) is int:
            raw = str(raw)
        if not isinstance(raw, str) or not re.fullmatch(r"[0-9]{1,5}", raw, flags=re.ASCII):
            raise AgentError(422, "Setiap port harus angka.")
        num = int(raw)
        if not 1024 <= num <= 65535:
            raise AgentError(422, f"Port {num} di luar 1024-65535.")
        cleaned.append(str(num))
    if len(set(cleaned)) != len(cleaned):
        raise AgentError(422, "Daftar port duplikat.")
    ssh_port = body.get("ssh_port")
    if ssh_port not in (None, ""):
        if str(ssh_port) not in cleaned:
            raise AgentError(422, "ssh_port harus termasuk dalam daftar ports.")
        cleaned.remove(str(ssh_port))
        cleaned.insert(0, str(ssh_port))

    env = {
        "IMG_KEY": v_choice(body.get("image", "ubuntu22"), IMAGES, "image"),
        "CPU": str(v_int(body, "cpu", 1, 1, 128)),
        "RAM": str(v_int(body, "ram", 1024, 128, 1048576)),
        "DISK": str(v_int(body, "disk", 10, 1, 10000)),
        "NPORTS": str(len(cleaned)),
        "PLAN_TYPE": v_choice(body.get("plan", "shared"), ("shared", "dedicated"), "plan"),
        "VTYPE": "2" if v_choice(body.get("backend", "container"), ("container", "vm"), "backend") == "vm" else "1",
        "EXPIRE": v_dur(body.get("expire", "0")),
        "OWNER": v_owner(body.get("owner")),
        "NESTING": "y" if body.get("nesting", True) else "n",
        "VPSNAT_ALLOC_PORTS": " ".join(cleaned),
    }
    pw = v_pass(body.get("password"))
    if pw:
        env["PASS"] = pw
    if body.get("bw_quota_gb") not in (None, ""):
        env["BW_QUOTA_GB"] = v_num(body["bw_quota_gb"], "bw_quota_gb", 1_000_000)
    if body.get("bw_rate_mbit") not in (None, ""):
        env["BW_LIMIT_MBIT"] = v_num(body["bw_rate_mbit"], "bw_rate_mbit", 100_000)

    def fn():
        return cli(["create", name, str(len(cleaned))], env, timeout=1800)

    return 202, spawn("create", name, fn)["id"]


def op_delete(name: str) -> tuple[int, str]:
    need_row(name)
    return 202, spawn("delete", name, lambda: cli(["delete", name], yes=True, timeout=600))["id"]


def op_power(name: str, action: str) -> tuple[int, str]:
    need_row(name)
    ensure_idle(name)
    rc, out = cli([action, name], timeout=180)
    _states_cache["t"] = 0.0
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_reinstall(name: str, image: str) -> tuple[int, str]:
    need_row(name)
    image = v_choice(image, IMAGES, "image")
    return 202, spawn("reinstall", name, lambda: cli(["reinstall", name], {"IMG_KEY": image}, yes=True, timeout=1800))["id"]


def op_resize(name: str, body: dict) -> tuple[int, str]:
    row = need_row(name)
    env = {
        "CPU": str(v_int(body, "cpu", row["cpu"], 1, 128)),
        "RAM": str(v_int(body, "ram", row["ram"], 128, 1048576)),
        "DISK": str(v_int(body, "disk", row["disk"], row["disk"], 10000)),
    }
    ensure_idle(name)
    rc, out = cli(["resize", name], env, timeout=600)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_password(name: str, body: dict) -> tuple[int, str]:
    """Ganti password root. Password baru dikembalikan di akhir output sebagai JSON
    satu baris, supaya panel (pemegang kredensial) bisa menyimpannya."""
    need_row(name)
    pw = v_pass(body.get("password"))
    ensure_idle(name)
    rc, out = cli(["passwd", name], {"PASS": pw} if pw else None, timeout=180)
    if rc != 0:
        raise AgentError(400, last_error(out))
    row = get_row(name) or {}
    return 200, out + "\n" + json.dumps({"password": row.get("password", "")})


def op_expire(name: str, body: dict) -> tuple[int, str]:
    need_row(name)
    value = v_dur(body.get("value"))
    ensure_idle(name)
    rc, out = cli(["set-expire", name, value], timeout=120)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_owner(name: str, body: dict) -> tuple[int, str]:
    need_row(name)
    owner = v_owner(body.get("owner"))
    rc, out = cli(["set-owner", name, owner], timeout=120)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_plan(name: str, body: dict) -> tuple[int, str]:
    need_row(name)
    plan = v_choice(body.get("plan"), ("shared", "dedicated"), "plan")
    ensure_idle(name)
    rc, out = cli(["set-type", name, plan], timeout=600)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_bandwidth(name: str, body: dict) -> tuple[int, str]:
    need_row(name)
    action = v_choice(body.get("action"), ("set", "limit", "reset"), "action")
    if action == "set":
        args = ["bandwidth", name, "set", v_num(body.get("quota_gb", 0), "quota_gb", 1_000_000), v_num(body.get("rate_mbit", 0), "rate_mbit", 100_000)]
    elif action == "limit":
        args = ["bandwidth", name, "limit", v_num(body.get("rate_mbit", 0), "rate_mbit", 100_000)]
    else:
        args = ["bandwidth", name, "reset"]
    ensure_idle(name)
    rc, out = cli(args, timeout=180)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_ports_add(name: str, body: dict) -> tuple[int, str]:
    need_row(name)
    env = {
        "PROTO": v_choice(body.get("proto", "tcp"), ("tcp", "udp", "both"), "proto"),
        "COUNT": str(v_int(body, "count", 1, 1, 500)),
    }
    ports = body.get("ports")
    if isinstance(ports, list) and ports:
        cleaned = []
        for item in ports:
            raw = item.get("public") if isinstance(item, dict) else item
            if not re.fullmatch(r"[0-9]{1,5}", str(raw)):
                raise AgentError(422, "Port dari panel tidak valid.")
            cleaned.append(str(int(raw)))
        if len(cleaned) != int(env["COUNT"]):
            raise AgentError(422, "Jumlah ports tidak cocok dengan count.")
        env["VPSNAT_ALLOC_PORTS"] = " ".join(cleaned)
    ensure_idle(name)
    rc, out = cli(["port-add", name], env, timeout=180)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


def op_ports_del(name: str, port: str) -> tuple[int, str]:
    need_row(name)
    if not (port.isascii() and port.isdigit() and 1 <= int(port) <= 65535):
        raise AgentError(422, "Port tidak valid.")
    ensure_idle(name)
    rc, out = cli(["port-del", name], {"EXT": port}, timeout=180)
    if rc != 0:
        raise AgentError(400, last_error(out))
    return 200, out


# --------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vpsnat-node"
    sys_version = ""
    timeout = 20

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    # -- helpers --
    def send_json(self, status: int, obj: dict) -> None:
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)

    def read_body(self) -> dict:
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get_all("Transfer-Encoding", []):
            self.close_connection = True
            raise AgentError(400, "Transfer-Encoding tidak didukung.")
        if len(lengths) > 1:
            self.close_connection = True
            raise AgentError(400, "Content-Length duplikat.")
        if not lengths:
            return {}
        raw = lengths[0].strip()
        if not re.fullmatch(r"[0-9]{1,9}", raw, flags=re.ASCII):
            self.close_connection = True
            raise AgentError(400, "Content-Length tidak valid.")
        n = int(raw)
        if n > MAX_BODY:
            self.close_connection = True
            raise AgentError(413, "Body terlalu besar.")
        if n == 0:
            return {}
        data = self.rfile.read(n)
        if len(data) != n:
            self.close_connection = True
            raise AgentError(400, "Body terpotong.")
        try:
            parsed = json.loads(data or b"{}")
        except (ValueError, UnicodeDecodeError):
            raise AgentError(400, "Body harus JSON valid.") from None
        if not isinstance(parsed, dict):
            raise AgentError(400, "Body harus objek JSON.")
        return parsed

    def authorize(self) -> None:
        expected = agent_token()
        if not expected:
            raise AgentError(503, "Token agent belum diatur. Jalankan: vpsnat node init")
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            raise AgentError(401, "Authorization Bearer wajib.")
        if not hmac.compare_digest(header[7:].strip().encode(), expected.encode()):
            raise AgentError(401, "Token node tidak valid.")

    # -- routing --
    def do_GET(self):
        self.handle("GET")

    def do_POST(self):
        self.handle("POST")

    def do_DELETE(self):
        self.handle("DELETE")

    def handle(self, method: str) -> None:
        path = urlparse(self.path).path
        try:
            if path == "/" or path == AGENT_PREFIX:
                return self.send_json(200, {"ok": True, "service": "vpsnat-node", "version": VERSION})
            if not path.startswith(AGENT_PREFIX + "/"):
                raise AgentError(404, "Not found.")
            self.authorize()
            body = self.read_body() if method in ("POST", "DELETE", "PUT") else {}
            status, payload = self.dispatch(method, path[len(AGENT_PREFIX):], body)
            self.send_json(status, payload if isinstance(payload, dict) else {"ok": True, "output": payload})
        except AgentError as exc:
            self.send_json(exc.status, {"ok": False, "error": exc.msg})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"vpsnat-node internal error: {exc!r}\n{traceback.format_exc()}\n")
            self.send_json(500, {"ok": False, "error": "Kesalahan internal node."})

    def dispatch(self, method: str, sub: str, body: dict):
        parts = [p for p in sub.split("/") if p]

        if parts == ["health"]:
            return 200, {"ok": True, "version": VERSION, "time": int(time.time())}

        if parts == ["system"]:
            return 200, {"ok": True, "system": system_info()}

        if parts == ["jobs"]:
            with _jobs_lock:
                items = sorted(JOBS.values(), key=lambda j: j["started"], reverse=True)[:30]
                return 200, {"ok": True, "jobs": [job_view(j) for j in items]}

        if len(parts) == 2 and parts[0] == "jobs":
            with _jobs_lock:
                job = JOBS.get(parts[1])
                if not job:
                    raise AgentError(404, "Job tidak ditemukan.")
                return 200, {"ok": True, "job": job_view(job)}

        if parts == ["instances"]:
            if method == "GET":
                states = lxc_states()
                return 200, {"ok": True, "instances": [instance_view(r, states) for r in read_db()]}
            if method == "POST":
                status, job = op_create(body)
                return status, {"ok": True, "job": job}
            raise AgentError(405, "Method tidak didukung.")

        if len(parts) >= 2 and parts[0] == "instances":
            name = parts[1]
            if not SAFE_NAME_RE.fullmatch(name or ""):
                raise AgentError(404, "Instance tidak ditemukan.")
            rest = parts[2:]

            if not rest:
                if method == "GET":
                    return 200, {"ok": True, "instance": instance_view(need_row(name), secret=True)}
                if method == "DELETE":
                    status, job = op_delete(name)
                    return status, {"ok": True, "job": job}
                raise AgentError(405, "Method tidak didukung.")

            if rest == ["resources"] and method == "GET":
                return 200, {"ok": True, "res": instance_resources(need_row(name))}

            if rest == ["power"] and method == "POST":
                action = v_choice(body.get("action"), ("start", "stop", "restart", "suspend", "unsuspend"), "action")
                status, out = op_power(name, action)
                return status, {"ok": True, "output": out}

            if rest == ["reinstall"] and method == "POST":
                status, job = op_reinstall(name, body.get("image", "ubuntu22"))
                return status, {"ok": True, "job": job}

            if rest == ["resize"] and method == "POST":
                status, out = op_resize(name, body)
                return status, {"ok": True, "output": out}

            if rest == ["password"] and method == "POST":
                status, out = op_password(name, body)
                return status, {"ok": True, "output": out}

            if rest == ["expire"] and method == "POST":
                status, out = op_expire(name, body)
                return status, {"ok": True, "output": out}

            if rest == ["owner"] and method == "POST":
                status, out = op_owner(name, body)
                return status, {"ok": True, "output": out}

            if rest == ["plan"] and method == "POST":
                status, out = op_plan(name, body)
                return status, {"ok": True, "output": out}

            if rest == ["bandwidth"] and method == "POST":
                status, out = op_bandwidth(name, body)
                return status, {"ok": True, "output": out}

            if rest == ["ports"] and method == "POST":
                status, out = op_ports_add(name, body)
                return status, {"ok": True, "output": out}

            if len(rest) == 2 and rest[0] == "ports" and method == "DELETE":
                status, out = op_ports_del(name, rest[1])
                return status, {"ok": True, "output": out}

            raise AgentError(404, "Endpoint instance tidak dikenal.")

        raise AgentError(404, "Endpoint tidak dikenal.")


def system_info() -> dict:
    mem = {}
    with contextlib.suppress(OSError):
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                key, _, val = line.partition(":")
                parts = val.split()
                if parts:
                    mem[key] = to_int(parts[0]) * 1024
    uptime = 0
    with contextlib.suppress(OSError, ValueError, IndexError):
        with open("/proc/uptime", encoding="utf-8") as f:
            uptime = int(float(f.read().split()[0]))
    du = shutil.disk_usage("/")
    rc, lxd_ver = run_proc([LXC, "--version"], timeout=8)
    rows = read_db()
    states = lxc_states()
    identity = load_identity()
    return {
        "version": VERSION,
        "hostname": socket.gethostname(),
        "node_name": identity.get("name", ""),
        "public_ip": public_ip(),
        "cores": os.cpu_count() or 0,
        "load": [round(x, 2) for x in os.getloadavg()],
        "ram": {"total": mem.get("MemTotal", 0), "avail": mem.get("MemAvailable", 0)},
        "disk": {"total": du.total, "used": du.used},
        "uptime": uptime,
        "lxd_version": lxd_ver.strip().splitlines()[0] if rc == 0 and lxd_ver.strip() else "",
        "vps": {
            "total": len(rows),
            "running": sum(1 for r in rows if states.get(r["name"]) == "RUNNING" and not r["suspended"]),
            "suspended": sum(1 for r in rows if r["suspended"] == 1),
        },
        "storage_driver": conf().get("STORAGE_DRIVER", ""),
        "time": int(time.time()),
    }


class BoundedServer(ThreadingHTTPServer):
    max_workers = 32

    def __init__(self, *args, **kwargs):
        self._slots = threading.BoundedSemaphore(self.max_workers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            with contextlib.suppress(OSError):
                request.settimeout(1)
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


# --------------------------------------------------------------------------- entry
def cmd_serve(_args) -> int:
    c = conf()
    bind = os.environ.get("VPSNAT_NODE_BIND") or c.get("NODE_AGENT_BIND") or "0.0.0.0"
    port = to_int(os.environ.get("VPSNAT_NODE_PORT") or c.get("NODE_AGENT_PORT")) or 8788
    if not agent_token():
        sys.stderr.write("PERINGATAN: token node belum ada (jalankan: vpsnat node init).\n")
    load_jobs()
    server = BoundedServer((bind, port), Handler)
    server.daemon_threads = True
    sys.stderr.write(f"vpsnat-node listen {bind}:{port} (v{VERSION})\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def cmd_token(args) -> int:
    identity = load_identity()
    if args.rotate or not identity.get("token"):
        identity["token"] = secrets.token_hex(24)
        identity.setdefault("name", socket.gethostname())
        identity.setdefault("created", int(time.time()))
        save_identity(identity)
        with contextlib.suppress(OSError):
            os.makedirs(os.path.dirname(CONF), mode=0o700, exist_ok=True)
            _conf_set("NODE_TOKEN", identity["token"])
    print(identity["token"])
    return 0


def _conf_set(key: str, value: str) -> None:
    try:
        with open(CONF, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    out, done = [], False
    for line in lines:
        if line.startswith(f"{key}="):
            out.append(f"{key}={value}")
            done = True
        else:
            out.append(line)
    if not done:
        out.append(f"{key}={value}")
    tmp = f"{CONF}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, CONF)
    os.chmod(CONF, 0o600)


def cmd_identity(args) -> int:
    identity = load_identity()
    if args.name:
        identity["name"] = args.name
        save_identity(identity)
    print(json.dumps(identity, indent=2, ensure_ascii=False))
    return 0


def cmd_check(_args) -> int:
    info = system_info()
    info["agent_token_set"] = bool(agent_token())
    info["db_rows"] = len(read_db())
    print(json.dumps(info, indent=2, ensure_ascii=False))
    return 0 if info["db_rows"] >= 0 else 1


def cmd_attach(args) -> int:
    """Simpan token dari panel ke identitas node."""
    token = (args.token or "").strip()
    if not re.fullmatch(r"[0-9a-f]{16,96}", token):
        print("[x] Token tidak valid.", file=sys.stderr)
        return 1
    identity = load_identity()
    identity["token"] = token
    identity.setdefault("name", socket.gethostname())
    identity["attached"] = int(time.time())
    save_identity(identity)
    with contextlib.suppress(OSError):
        _conf_set("NODE_TOKEN", token)
    print("[+] Token panel tersimpan di", IDENTITY)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="vpsnat-node", description="VPSNAT node agent (data-plane)")
    parser.add_argument("--version", action="version", version=f"vpsnat-node {VERSION}")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("serve", help="jalankan daemon (default)")
    p = sub.add_parser("token", help="tampilkan / buat token agent")
    p.add_argument("--rotate", action="store_true")
    p = sub.add_parser("identity", help="tampilkan identitas node")
    p.add_argument("--name", default="")
    sub.add_parser("check", help="cetak status node sebagai JSON")
    p = sub.add_parser("attach", help="simpan token dari panel")
    p.add_argument("token")
    args = parser.parse_args(argv)
    cmd = args.cmd or "serve"
    return {
        "serve": cmd_serve,
        "token": cmd_token,
        "identity": cmd_identity,
        "check": cmd_check,
        "attach": cmd_attach,
    }[cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
