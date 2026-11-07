#!/usr/bin/env python3
"""Inti panel web: konfigurasi, helper HTTP, dan mesin UI.

Panel web TIDAK memanggil CLI `vpsnat` untuk data client. Sumber kebenaran ada
di panel DB (panel/db.py, SQLite), dan setiap operasi yang menyentuh mesin
client dikirim ke NODE lewat agent sebagai job (panel/jobs.py + nodeclient.py).

Modul ini menyediakan konstanta, panel DB, sesi/rate-limit, validasi input,
job registry, aset PWA, dan server HTTP + router `route()` / `page()` yang
dipakai modul halaman di panel/web/pages/.
"""
from __future__ import annotations

import contextlib
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
import signal
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
WEB_ROOT = os.path.join(HERE, "web")
if WEB_ROOT not in sys.path:
    sys.path.insert(0, WEB_ROOT)

import db  # noqa: E402
import jobs  # noqa: E402
from nodeclient import NodeClient, NodeError  # noqa: E402

SCRYPT = dict(n=2**14, r=8, p=1, dklen=32)
VERSION = "4.0.0"


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


APP_DIR = HERE
PANEL_DB = os.environ.get("VPSNAT_PANEL_DB", "/etc/vpsnat/panel.db")
CONF = os.environ.get("VPSNAT_WEB_CONF", "/etc/vpsnat/vpsnat.conf")
AUDIT = os.environ.get("VPSNAT_WEB_AUDIT", "/etc/vpsnat/audit.log")
CLI = os.environ.get("VPSNAT_WEB_CLI", "/usr/local/bin/vpsnat")
WEB_DIR = os.environ.get("VPSNAT_WEB_DIR", WEB_ROOT)
PAGES_DIR = os.path.join(WEB_DIR, "pages")
PAGES_PKG = "pages"
COOKIE = "vpsnat_session"
MAX_BODY = 65536
DUMMY_HASH = hash_password("dummy-password-for-timing")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
PASS_RE = re.compile(r"^[A-Za-z0-9@%^*_+=.,:;!?~-]{8,64}$")
DUR_RE = re.compile(r"^([0-9]+[hdwm]|[0-9]{4}-[0-9]{2}-[0-9]{2}|never|0)$", re.ASCII)
REL_DUR_RE = re.compile(r"^[0-9]+[hdwm]$", re.ASCII)
OWNER_RE = re.compile(r"^[^|\r\n]{1,60}$")
IMAGES = ("ubuntu24", "ubuntu22", "ubuntu20", "debian12", "debian11", "alma9", "rocky9", "alpine")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PASS_LINE_RE = re.compile(r"(?im)^(.*password[^:\n]*:\s*).*$")
NUM_RE = re.compile(r"^\d+(\.\d+)?$")
SETTING_KEYS = {
    "brand": "brand",
    "node-sync-seconds": "node_sync_seconds",
    "job-timeout": "job_timeout",
    "grace-days": "grace_days",
    "default-ports": "default_ports",
    "ports-min": "ports_min",
    "ports-max": "ports_max",
    "default-quota-gb": "default_quota_gb",
    "default-rate-mbit": "default_rate_mbit",
    "allow-user-reinstall": "allow_user_reinstall",
}
PORTS_MIN, PORTS_MAX = 2, 50


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


def setting(key, default="", db_path=None):
    try:
        return db.setting(key, default, db_path)
    except Exception:  # noqa: BLE001
        return default


def setting_int(key, default, db_path=None):
    raw = str(setting(key, "", db_path)).strip()
    return int(raw) if raw.isdigit() else default


def to_int(v):
    """Strict integer parser; never truncates floats."""
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


# ---------- nodes ----------
def nodes_all():
    return db.nodes_all()


def node_get(name_or_id, token=False):
    return db.node_get(name_or_id, with_token=token)


def client_for(nid, timeout=30.0):
    node = db.node_get(nid, with_token=True)
    if not node:
        raise ApiError(503, "Node tidak ditemukan di panel.")
    return NodeClient(str(node.get("url") or ""), str(node.get("token") or ""), timeout=timeout)


def node_online(nid) -> bool:
    window = max(120, setting_int("node_sync_seconds", 15) * 8)
    for n in db.nodes_all():
        if n["id"] == nid:
            return bool(n["last_seen"]) and (time.time() - int(n["last_seen"]) < window)
    return False


def node_name(nid) -> str:
    for n in db.nodes_all():
        if n["id"] == nid:
            return n["name"]
    return f"#{nid}"


# ---------- process helpers ----------
def run_proc(argv, env=None, timeout=900):
    """Jalankan proses dalam process group sendiri supaya timeout juga membunuh anaknya."""
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
    except OSError as exc:
        return 127, f"Perintah tidak dapat dijalankan: {exc}"
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(p.pid, signal.SIGTERM)
        try:
            out, _ = p.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(p.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                out, _ = p.communicate(timeout=2)
            if not isinstance(out, (bytes, bytearray)):
                out = b""
        return 124, "Timeout: seluruh process group dihentikan.\n" + (out or b"").decode(errors="replace")
    return p.returncode, (out or b"").decode(errors="replace")


def clean(out, limit=6000):
    text = ANSI_RE.sub("", out or "")
    text = PASS_LINE_RE.sub(lambda m: m.group(1) + "********", text).strip()
    return text if len(text) <= limit else "…" + text[-limit:]


def cli(args, env=None, yes=False, timeout=900):
    """CLI lokal — khusus perintah panel (settings/audit), bukan operasi VPS client."""
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
    if not NAME_RE.fullmatch(v):
        raise ApiError(422, "Nama tidak valid (a-z, 0-9, -; maks 31 karakter).")
    return v


def v_int(b, key, default, lo, hi):
    v = b.get(key, default)
    # bool adalah subclass int di Python; float tidak boleh dipotong diam-diam.
    if type(v) is int:
        n = v
    elif isinstance(v, str) and re.fullmatch(r"[0-9]{1,12}", v.strip(), flags=re.ASCII):
        n = int(v.strip(), 10)
    else:
        raise ApiError(422, f"{key} harus integer tanpa pecahan.")
    if not lo <= n <= hi:
        raise ApiError(422, f"{key} harus {lo}-{hi}.")
    return n


def v_num(v, key, hi, lo=0):
    if type(v) not in (int, float, str):
        raise ApiError(422, f"{key} harus angka {lo}-{hi}.")
    s = str(v).strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", s, flags=re.ASCII):
        raise ApiError(422, f"{key} harus angka {lo}-{hi}.")
    try:
        n = float(s)
    except (ValueError, OverflowError):
        raise ApiError(422, f"{key} harus angka {lo}-{hi}.") from None
    if not math.isfinite(n) or n < lo or n > hi:
        raise ApiError(422, f"{key} harus angka {lo}-{hi}.")
    return s


def v_choice(v, choices, key):
    if v not in choices:
        raise ApiError(422, f"{key} harus salah satu: {', '.join(choices)}.")
    return v


def v_bool(v, key, default=False):
    if v is None:
        return default
    if type(v) is not bool:
        raise ApiError(422, f"{key} harus boolean true/false.")
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
    if not (REL_DUR_RE if relative else DUR_RE).fullmatch(v):
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
        raise ApiError(422, "Tanggal expiry tidak valid (gunakan YYYY-MM-DD).") from None
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
    server = db.server_get(name)
    with _sess_lock:
        for t in [t for t, s in SESSIONS.items() if s["role"] == "user" and s["name"] == name and t != keep_token]:
            del SESSIONS[t]
        if keep_token and keep_token in SESSIONS and server:
            SESSIONS[keep_token]["fp"] = pw_fp(server["password"])


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
            # Buang entri paling lama, JANGAN reset seluruh counter: `clear()` bisa
            # dipicu penyerang dengan membanjiri 10.000 key lalu brute force ulang.
            for stale in sorted(_fails, key=lambda k: _fails[k][-1])[:2000]:
                _fails.pop(stale, None)
        for k in keys:
            _fails.setdefault(k, []).append(now)


def throttle(ip, ident=None):
    wait = blocked(f"ip:{ip}", 5)
    if ident:
        wait = max(wait, blocked(f"id:{ident}", 20))
    if wait:
        raise ApiError(429, f"Terlalu banyak percobaan gagal. Coba lagi dalam {wait} detik.")


def pw_fp(password):
    return hashlib.sha256((password or "").encode()).hexdigest()


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
        if self.auth and self.auth["role"] == "admin":
            return "admin"
        return (self.auth or {}).get("name", "-")


ROUTES = []
PAGE_ROUTES = {}


def route(method, pattern, role=None):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), role, fn))
        return fn

    return deco


def page(pattern):
    """Daftarkan halaman UI (HTML berdiri sendiri di panel/web/pages/)."""

    def deco(fn):
        PAGE_ROUTES[re.compile("^" + pattern + "$")] = fn
        return fn

    return deco


# Nama di route lebih longgar dari v_name(): server hasil sync/import tetap bisa dibuka.
NAME = r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]{0,62})"
MID = r"(?P<mid>[A-Za-z0-9][A-Za-z0-9._-]{0,62})"


def store_audit_file(actor, action, target, result="ok", detail=""):
    """Audit trail: file JSONL (dibaca `vpsnat audit`) + tabel audit panel."""
    try:
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "actor": str(actor)[:120], "action": str(action)[:60], "target": str(target)[:120],
                "result": str(result)[:20], "detail": str(detail)[:400],
            }, ensure_ascii=False) + "\n")
    except OSError:
        pass
    db.audit_add(actor, action, target, result, detail)


# ---------- PWA ----------
PWA_REV = "2"  # naikkan jika isi service worker/ikon berubah
PWA_THEME = "#2563eb"
PWA_ICONS = {"/icon-192.png": 192, "/icon-512.png": 512, "/apple-touch-icon.png": 180}
PWA_PATHS = frozenset({"/manifest.webmanifest", "/sw.js", *PWA_ICONS})

# Service worker TIDAK menyentuh /api/*: sesi, password VPS, dan data resource tidak
# pernah masuk cache. Yang di-cache hanya shell HTML (tanpa data), CSS/JS, manifest, ikon.
PWA_SW = r"""'use strict';
const CACHE = 'vpsnat-%V%';
const ASSETS = ['/static/css/app.css', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png', '/apple-touch-icon.png'];
const OFFLINE = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Offline</title><body style="margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#f8fafc;color:#0f172a;text-align:center"><div style="padding:24px"><h1 style="font-size:20px">Tidak ada koneksi</h1><p style="color:#64748b">Panel butuh koneksi ke server. Coba lagi setelah online.</p><button onclick="location.reload()" style="padding:10px 18px;border:0;border-radius:10px;background:#2563eb;color:#fff;font:inherit;font-weight:600">Muat ulang</button></div>';
self.addEventListener('install', e => e.waitUntil(
  caches.open(CACHE).then(c => c.addAll(['/'].concat(ASSETS)).catch(() => {})).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== self.location.origin || u.pathname.startsWith('/api/')) return;
  if (r.mode === 'navigate') {
    e.respondWith(fetch(r).then(res => {
      if (res.ok) { const cp = res.clone(); e.waitUntil(caches.open(CACHE).then(c => c.put(r, cp))); }
      return res;
    }).catch(() => caches.match(r).then(m => m || caches.match('/')).then(m => m || new Response(OFFLINE, {status: 503, headers: {'Content-Type': 'text/html; charset=utf-8'}}))));
    return;
  }
  if (u.pathname.startsWith('/static/') || ASSETS.includes(u.pathname)) e.respondWith(caches.match(r).then(m => m || fetch(r)));
});
"""


def branding():
    brand = conf().get("WEB_BRAND") or setting("brand", "") or "VPSNAT"
    logo = conf().get("WEB_LOGO_URL", "")
    return {"brand": (brand or "VPSNAT")[:40], "logo": logo if logo.startswith("https://") else ""}


def load_page(rel):
    base = os.path.realpath(PAGES_DIR)
    path = os.path.realpath(os.path.join(PAGES_DIR, rel))
    if not path.startswith(base + os.sep):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def ui_version():
    """Versi aset UI: berubah bila halaman/CSS/JS/branding berubah (dipakai cache PWA)."""
    h = hashlib.sha256()
    for root, _dirs, files in os.walk(WEB_DIR):
        for name in sorted(files):
            if name.endswith(".py"):
                continue
            path = os.path.join(root, name)
            h.update(os.path.relpath(path, WEB_DIR).encode())
            with contextlib.suppress(OSError):
                with open(path, "rb") as f:
                    h.update(f.read())
    h.update((PWA_REV + branding()["brand"] + VERSION).encode())
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
class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """Batasi thread request: tolak kelebihan beban alih-alih menghabiskan memori."""

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


STATIC_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".webmanifest": "application/manifest+json; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".ico": "image/x-icon",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vpsnat-panel"
    sys_version = ""
    timeout = 15

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_ip(), fmt % args))

    def client_ip(self):
        c = conf()
        remote = self.client_address[0]
        if c.get("WEB_TRUST_PROXY") == "1":
            try:
                trusted = ipaddress.ip_address(remote).is_loopback
            except ValueError:
                trusted = False
            # Reverse proxy non-loopback harus terdaftar eksplisit.
            trusted_ips = {item.strip() for item in (c.get("WEB_TRUST_PROXY_IPS") or "").split(",") if item.strip()}
            trusted = trusted or remote in trusted_ips
            if trusted:
                header = c.get("WEB_IP_HEADER") or "X-Forwarded-For"
                fwd = (self.headers.get(header) or "").split(",")[-1].strip()
                if fwd:
                    with contextlib.suppress(ValueError):
                        return str(ipaddress.ip_address(fwd))
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

    def origin_ok(self):
        """True bila Origin/Referer cocok dengan Host panel (proteksi CSRF lapis kedua)."""
        raw = (self.headers.get("Origin") or "").strip()
        if not raw:
            raw = (self.headers.get("Referer") or "").strip()
            if not raw:
                return True
        if raw == "null":
            return False
        host = (self.headers.get("Host") or "").strip().lower()
        if not host:
            return False
        try:
            parts = urlsplit(raw)
        except ValueError:
            return False
        return bool(parts.netloc) and parts.netloc.lower() == host

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
            server = db.server_get(s["name"])
            # Reinstall mengganti password di tengah job; sesi diperbarui setelah job selesai.
            if not server or (pw_fp(server["password"]) != s["fp"] and not jobs.busy(server["name"])):
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
            js = PWA_SW.replace("%V%", ui_version()).encode()
            return self.send_bytes(200, "text/javascript; charset=utf-8", js, extra=[("Service-Worker-Allowed", "/")])
        return self.send_bytes(200, "image/png", pwa_icon(PWA_ICONS[path]))

    def send_static(self, path):
        base = os.path.realpath(os.path.join(WEB_DIR, "static"))
        target = os.path.realpath(os.path.join(base, path[len("/static/"):].lstrip("/")))
        if not target.startswith(base + os.sep) or not os.path.isfile(target):
            return self.send_json(404, {"ok": False, "error": "Berkas tidak ditemukan."})
        try:
            with open(target, "rb") as f:
                data = f.read()
        except OSError:
            return self.send_json(404, {"ok": False, "error": "Berkas tidak ditemukan."})
        ctype = STATIC_TYPES.get(os.path.splitext(target)[1], "application/octet-stream")
        return self.send_bytes(200, ctype, data)

    def send_page(self, rel, nonce):
        html = load_page(rel)
        if html is None:
            return self.send_json(404, {"ok": False, "error": f"Halaman {rel} tidak ada di paket panel."})
        html = (html.replace("{{NONCE}}", nonce)
                    .replace("{{BRAND}}", branding()["brand"])
                    .replace("{{VERSION}}", VERSION)
                    .replace("{{UIVER}}", ui_version()))
        return self.send_bytes(200, "text/html; charset=utf-8", html.encode(), nonce=nonce)

    def read_body(self):
        # Server ini tidak mengimplementasikan request chunked; tolak framing ambigu.
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
            # read1 + deadline absolut: klien tidak bisa menahan worker dengan mengirim
            # byte pelan-pelan di bawah socket timeout.
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
            raise ApiError(400, "Body request tidak lengkap atau melewati batas waktu.") from None
        finally:
            with contextlib.suppress(OSError):
                self.connection.settimeout(self.timeout)
        if len(raw) != n:
            self.close_connection = True
            raise ApiError(400, "Body request terpotong.")
        self._body_read = True
        try:
            data = json.loads(raw, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
        except (ValueError, UnicodeDecodeError, RecursionError):
            self.close_connection = True
            raise ApiError(400, "Body harus JSON valid (NaN/Infinity dan nesting ekstrem tidak diizinkan).") from None
        if not isinstance(data, dict):
            raise ApiError(400, "Body harus objek JSON.")
        return data

    def handle_any(self, method):
        self._body_read = False
        if method == "GET":
            transfer = self.headers.get_all("Transfer-Encoding", [])
            lengths = self.headers.get_all("Content-Length", [])
            invalid_length = len(lengths) > 1 or any(
                not re.fullmatch(r"0+", item.strip(), flags=re.ASCII) for item in lengths
            )
            if transfer or invalid_length:
                self.close_connection = True
                return self.send_json(400, {"ok": False, "error": "GET tidak menerima body atau framing ambigu."})
        path = urlparse(self.path).path

        if method == "GET":
            if path == "/favicon.ico":
                return self.send_bytes(204, "image/x-icon", b"")
            if path in PWA_PATHS:
                return self.send_pwa(path)
            if path.startswith("/static/"):
                return self.send_static(path)
            for rx, fn in PAGE_ROUTES.items():
                match = rx.match(path)
                if match:
                    rel = fn(**match.groupdict()) if match.groupdict() else fn()
                    if rel:
                        return self.send_page(rel, secrets.token_urlsafe(16))
                    break
            if path == "/":
                return self.send_page("dashboard.html", secrets.token_urlsafe(16))

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
            body = self.read_body() if method in ("POST", "DELETE", "PUT") else {}
            auth = self.authenticate(ip)
            if method != "GET" and (not auth or auth.get("via") == "cookie"):
                if self.headers.get("X-Requested-With") != "vpsnat":
                    raise ApiError(403, "Header X-Requested-With wajib.")
                # Header X-Requested-With saja tidak cukup: request lintas-origin dapat
                # mengirimnya, jadi Origin/Referer asing harus ditolak untuk auth cookie.
                if auth and not self.origin_ok():
                    raise ApiError(403, "Origin tidak diizinkan untuk permintaan ini.")
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
            if method in ("POST", "DELETE", "PUT") and not self._body_read and lengths:
                self.close_connection = True  # sisa body belum dibaca; koneksi tidak boleh dipakai ulang
            self.send_json(exc.status, {"ok": False, "error": exc.msg})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"internal error: {exc!r}\n")
            self.send_json(500, {"ok": False, "error": "Kesalahan internal."})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


PAGE_MODULES = ("core_api", "servers", "nodes", "openapi")


def load_pages():
    """Import modul halaman supaya route()-nya terdaftar (dipanggil sebelum serve).

    Saat app.py dijalankan langsung, ia berperan sebagai modul `__main__`. Modul
    halaman meng-`import app`, dan itu akan MENGEKSEKUSI app.py sekali lagi sebagai
    modul terpisah: route() mereka mendaftar ke salinan lain, sehingga router di
    proses ini tetap kosong. Karena itu `__main__` didaftarkan sebagai `app` lebih
    dulu (sys.modules), supaya hanya ada satu objek modul untuk seluruh proses.
    """
    import importlib

    sys.modules.setdefault("app", sys.modules[__name__])
    sys.modules.setdefault("panelapp", sys.modules[__name__])
    loaded = []
    for name in PAGE_MODULES:
        try:
            importlib.import_module(f"{PAGES_PKG}.{name}")
            loaded.append(name)
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"panel: gagal memuat modul halaman {name}: {exc!r}\n")
    if not loaded:
        sys.stderr.write(
            f"panel: TIDAK ada modul halaman yang dimuat (dir={PAGES_DIR}, sys.path={sys.path[:3]}).\n"
        )
    return loaded


def main():
    c = conf()
    bind = c.get("WEB_BIND") or "0.0.0.0"
    port = to_int(c.get("WEB_PORT")) or 8787
    if not c.get("WEB_ADMIN_HASH"):
        sys.stderr.write("PERINGATAN: WEB_ADMIN_HASH belum diset (vpsnat web-setup).\n")
    db.connect().close()
    jobs.interrupt_running()
    load_pages()
    server = BoundedThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    sys.stderr.write(
        f"vpsnat-panel listen {bind}:{port} (v{VERSION}, {len(ROUTES)} endpoint, {len(PAGE_ROUTES)} halaman)\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":  # dipakai bila dijalankan langsung (mis. dari systemd unit lama)
    if len(sys.argv) > 1 and sys.argv[1] == "hashpw":
        print(hash_password(sys.stdin.read().rstrip("\r\n")))
    else:
        main()
