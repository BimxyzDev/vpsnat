#!/usr/bin/env python3
"""Panel web: autentikasi, sesi, endpoint bersama (session/logout/jobs/settings).

Juga berisi helper tampilan server (`vps_view`) yang dipakai halaman server dan
halaman user, karena keduanya membaca satu bentuk data yang sama dari panel DB.
"""
from __future__ import annotations

import hmac
import json
import os
import shutil
import time

import app
import db
import jobs
from app import (  # noqa: F401
    ApiError, DUMMY_HASH, PORTS_MAX, PORTS_MIN, SETTING_KEYS, branding, client_for, conf,
    db, drop_session, fail, new_session, pw_fp, refresh_sessions, route, setting,
    setting_int, throttle, to_int, v_choice, v_int, v_num, verify_password,
)


# ---------------------------------------------------------------- session & auth
@route("GET", "/api/session")
def session_info(req):
    return {"ok": True, **branding(), "role": (req.auth or {}).get("role"), "name": (req.auth or {}).get("name")}


@route("GET", "/api/panel")
def panel_info(req):
    """Info panel tanpa data sensitif — dipakai halaman login."""
    return {
        "ok": True,
        **branding(),
        "version": app.VERSION,
        "role": (req.auth or {}).get("role"),
        "nodes": len(db.nodes_all()) if req.auth else 0,
    }


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
    db.audit_add("admin", "login.admin", "-", "ok", f"ip={req.ip}")
    return {"ok": True, "role": "admin"}


@route("POST", "/api/login/user")
def login_user(req):
    b = req.body
    ident = str(b.get("identifier", "")).strip().lower()[:64]
    throttle(req.ip, ident)
    password = str(b.get("password", ""))[:200]
    server = None
    if ident.isascii() and ident.isdigit():
        server = db.server_by_ssh_port(int(ident))
    if server is None:
        server = db.server_get(ident)
    usable = server is not None and server.get("password") not in ("", "-", "unknown")
    expected = (server or {}).get("password") if usable else "x" * 16
    ok = usable and bool(password) and hmac.compare_digest(password.encode(), str(expected).encode())
    if not ok:
        fail(f"ip:{req.ip}", f"id:{ident}")
        raise ApiError(401, "Server atau password salah.")
    token, ttl = new_session("user", server["name"], pw_fp(server["password"]))
    req.set_cookie = (token, ttl)
    db.audit_add(server["name"], "login.user", server["name"], "ok", f"ip={req.ip}")
    return {"ok": True, "role": "user", "name": server["name"]}


@route("POST", "/api/logout")
def logout(req):
    tok = req.h.session_token()
    if tok:
        drop_session(tok)
    req.clear_cookie = True
    return {"ok": True}


# ---------------------------------------------------------------- shared views
def server_view(row: dict, node: dict | None = None, with_password: bool = False) -> dict:
    node = node or db.node_get(int(row["node_id"]))
    host = str((node or {}).get("wan_ip") or "")
    node_label = str((node or {}).get("name") or f"#{row['node_id']}")
    ssh_ports = list(db.allocations_of(int(row["id"])))
    return {
        "id": row["id"],
        "uuid": row["uuid"],
        "name": row["name"],
        "node": node_label,
        "node_id": row["node_id"],
        "node_online": app.node_online(int(row["node_id"])),
        "owner": row["owner"],
        "plan": row["plan"],
        "backend": row["backend"],
        "image": row["image"],
        "cpu": row["cpu"],
        "ram": row["ram"],
        "disk": row["disk"],
        "created": row["created"],
        "expires": row["expires"],
        "suspended": bool(row["suspended"]),
        "reason": row["reason"],
        "state": "SUSPEND" if row["suspended"] else row["state"],
        "host": host,
        "ssh": row["ssh_port"],
        "ports": [
            {"public": p, "internal": 22 if p == row["ssh_port"] else p,
             "proto": "tcp" if p == row["ssh_port"] else "tcp+udp", "ssh": p == row["ssh_port"]}
            for p in ssh_ports
        ],
        "bw": {
            "used": int(row["bw_rx"]) + int(row["bw_tx"]),
            "rx": int(row["bw_rx"]),
            "tx": int(row["bw_tx"]),
            "quota": int(row["bw_quota"]),
            "rate": float(row["bw_rate"]),
            "exhausted": False,
        },
        "last_error": row.get("last_error", ""),
        **({"password": row["password"]} if with_password else {}),
    }


def need_server(name: str) -> dict:
    """Ambil server dari panel DB dan pastikan namanya aman dipakai di URL node."""
    if not app.SAFE_NAME_RE.fullmatch(name or ""):
        raise ApiError(404, "Server tidak ditemukan.")
    row = db.server_get(name)
    if not row:
        raise ApiError(404, "Server tidak ditemukan.")
    return row


def node_for(row: dict) -> dict:
    node = db.node_get(int(row["node_id"]))
    if not node:
        raise ApiError(503, "Node server ini tidak ada di panel.")
    if not app.node_online(int(row["node_id"])):
        raise ApiError(503, f"Node '{node['name']}' tidak terhubung. Periksa node lalu coba lagi.")
    return node


def node_call(row: dict, method: str, *args, **kwargs):
    """Panggil agent node; ubah kegagalan transport jadi ApiError yang rapi."""
    node_for(row)
    client = client_for(int(row["node_id"]))
    try:
        return getattr(client, method)(*args, **kwargs)
    except Exception as exc:  # noqa: BLE001
        if hasattr(exc, "status"):
            raise ApiError(400, str(exc)) from exc
        raise ApiError(503, f"Node tidak merespons: {exc}") from exc


def pull_state(row: dict, quiet: bool = False) -> str:
    """Tarik state terbaru satu server dari node ke panel DB."""
    try:
        inst = node_call(row, "instance", row["name"])
    except ApiError:
        if not quiet:
            raise
        return row["state"]
    state = str(inst.get("state") or "UNKNOWN").upper()
    changes: dict = {"state": state, "last_error": ""}
    if inst.get("suspended") is not None:
        changes["suspended"] = 1 if inst["suspended"] else 0
    if inst.get("reason"):
        changes["reason"] = str(inst["reason"])[:120]
    bw = inst.get("bw") or {}
    for key, src in (("bw_rx", "rx"), ("bw_tx", "tx")):
        if bw.get(src) is not None:
            changes[key] = to_int(bw.get(src))
    if inst.get("password"):
        changes["password"] = inst["password"]
    db.server_update(row["name"], **changes)
    return state


def expire_epoch(value: str) -> int:
    """Ubah nilai durasi/tanggal jadi epoch detik (0 = tanpa expired)."""
    if value in ("0", "never", ""):
        return 0
    if value.isdigit():
        return int(value)
    import datetime as _dt
    import re as _re

    m = _re.fullmatch(r"([0-9]+)([hdwm])", value)
    now = _dt.datetime.now()
    if m:
        num, unit = int(m.group(1)), m.group(2)
        delta = {"h": _dt.timedelta(hours=num), "d": _dt.timedelta(days=num),
                 "w": _dt.timedelta(weeks=num), "m": _dt.timedelta(days=num * 30)}[unit]
        return int((now + delta).timestamp())
    d = _dt.datetime.strptime(value, "%Y-%m-%d").replace(hour=23, minute=59, second=59)
    return int(d.timestamp())


# ---------------------------------------------------------------- jobs API
@route("GET", "/api/jobs")
def any_jobs(req):
    """Daftar job milik pemanggil (admin: semua, user: miliknya)."""
    if not req.auth:
        raise ApiError(401, "Belum login.")
    items = db.jobs_recent(30)
    if req.auth["role"] != "admin":
        items = [j for j in items if j["target"] == req.auth["name"]]
    return {"ok": True, "jobs": [jobs.view(j) for j in items]}


@route("GET", r"/api/jobs/(?P<jid>[0-9a-f]{12})")
def any_job(req, jid):
    if not req.auth:
        raise ApiError(401, "Belum login.")
    job = db.job_get(jid)
    if not job:
        raise ApiError(404, "Job tidak ditemukan.")
    if req.auth["role"] != "admin" and job["target"] != req.auth["name"]:
        raise ApiError(403, "Job ini bukan milikmu.")
    if job["status"] != "running":
        refresh_sessions(job["target"], req.h.session_token())
    return {"ok": True, "job": jobs.view(job)}


@route("GET", "/api/admin/jobs", "admin")
def a_jobs(req):
    return {"ok": True, "jobs": [jobs.view(j) for j in db.jobs_recent(30)]}


@route("GET", r"/api/admin/jobs/(?P<jid>[0-9a-f]{12})", "admin")
def a_job(req, jid):
    job = db.job_get(jid)
    if not job:
        raise ApiError(404, "Job tidak ditemukan.")
    if job["status"] != "running":
        refresh_sessions(job["target"], req.h.session_token())
    return {"ok": True, "job": jobs.view(job)}


# ---------------------------------------------------------------- settings
@route("GET", "/api/admin/settings", "admin")
def a_settings(req):
    return {
        "ok": True,
        "settings": db.settings_all(),
        "keys": list(SETTING_KEYS),
        "values": {k: setting(k, "") for k in SETTING_KEYS.values()},
    }


@route("POST", "/api/admin/settings", "admin")
def a_settings_set(req):
    key = v_choice(req.body.get("key"), tuple(SETTING_KEYS), "key")
    name = SETTING_KEYS[key]
    raw = req.body.get("value")
    if name in ("allow_user_reinstall",):
        value = "1" if app.v_bool(raw, "value", False) else "0"
    elif name == "brand":
        text = str(raw or "").strip()
        if not text or len(text) > 40:
            raise ApiError(422, "brand harus 1-40 karakter.")
        value = text
    elif name in ("ports_min", "ports_max", "default_ports"):
        value = str(v_int(req.body, "value", setting_int(name, 3), 1, 65535))
    elif name in ("default_quota_gb", "default_rate_mbit"):
        value = v_num(raw, "value", 1_000_000)
    else:
        value = str(v_int(req.body, "value", setting_int(name, 15), 1, 1_000_000))
    db.setting_set(name, value)
    app.store_audit_file(req.who, "settings.set", name, "ok", f"value={value}")
    return {"ok": True, "settings": db.settings_all()}


@route("GET", "/api/admin/audit", "admin")
def a_audit(req):
    return {"ok": True, "audit": db.audit_recent(100)}


# ---------------------------------------------------------------- halaman UI
app.page("/")(lambda: "dashboard.html")
app.page("/login")(lambda: "login.html")
app.page("/servers")(lambda: "servers.html")
app.page(r"/servers/(?P<name>[A-Za-z0-9][A-Za-z0-9._-]{0,62})")(lambda name: "server.html")
app.page("/jobs")(lambda: "jobs.html")
app.page("/settings")(lambda: "settings.html")
app.page("/account")(lambda: "account.html")
app.page("/api-docs")(lambda: "api.html")
