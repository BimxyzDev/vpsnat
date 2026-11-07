#!/usr/bin/env python3
"""Panel web: registry node, alokasi port, dan sinkronisasi.

Endpoint ini menjawab pertanyaan operasional: node mana yang online, berapa port
yang masih kosong, dan bagaimana memperbaiki node yang token/URL-nya berubah.
"""
from __future__ import annotations

import json
import time

import app
import db
import sync as syncmod
from app import ApiError, PORTS_MAX, PORTS_MIN, route, setting_int, v_bool, v_int
from app import re as re

TOKEN_RE = re.compile(r"^[0-9a-f]{16,96}$")


def node_view(node: dict, alloc: dict | None = None) -> dict:
    try:
        info = json.loads(node.get("system_json") or "{}")
    except (ValueError, TypeError):
        info = {}
    st = alloc or {}
    return {
        "id": node["id"],
        "name": node["name"],
        "url": node["url"],
        "wan_ip": node["wan_ip"],
        "port_min": node["port_min"],
        "port_max": node["port_max"],
        "description": node["description"],
        "maintenance": bool(node["maintenance"]),
        "online": app.node_online(node["id"]),
        "last_seen": node["last_seen"],
        "status": node["last_status"],
        "error": node["last_error"],
        "ports_total": st.get("total", int(node["port_max"]) - int(node["port_min"]) + 1),
        "ports_free": st.get("free", 0),
        "system": {
            "cores": info.get("cores"),
            "load": info.get("load"),
            "ram": info.get("ram"),
            "disk": info.get("disk"),
            "uptime": info.get("uptime"),
            "vps": info.get("vps"),
            "public_ip": info.get("public_ip"),
            "lxd_version": info.get("lxd_version"),
            "storage_driver": info.get("storage_driver"),
        },
    }


def all_node_views() -> list[dict]:
    alloc = db.allocations_stats()
    return [node_view(n, alloc.get(n["id"])) for n in db.nodes_all()]


def normalize_url(raw: str) -> str:
    url = str(raw or "").strip().rstrip("/")
    if not url:
        return ""
    if not url.startswith(("http://", "https://")):
        url = "http://" + url
    host = url.split("://", 1)[1]
    if ":" not in host:
        url = f"{url}:8788"
    return url


@route("GET", "/api/admin/nodes", "admin")
def a_nodes(req):
    return {"ok": True, "nodes": all_node_views()}


@route("POST", "/api/admin/nodes", "admin")
def a_node_create(req):
    b = req.body
    name = app.v_name(b.get("name"))
    if db.node_get(name):
        raise ApiError(409, "Node dengan nama itu sudah ada.")
    wan = str(b.get("wan_ip") or "").strip()
    if not wan or not all(p.isdigit() and 0 <= int(p) <= 255 for p in wan.split(".")) or len(wan.split(".")) != 4:
        raise ApiError(422, "wan_ip wajib IPv4 node (IP yang dipakai client untuk SSH).")
    url = normalize_url(b.get("url") or f"http://{wan}:8788")
    lo = v_int(b, "port_min", 20000, 1024, 65535)
    hi = v_int(b, "port_max", min(65535, lo + 4999), 1024, 65535)
    if hi < lo:
        raise ApiError(422, "port_max harus >= port_min.")
    if lo < 1024:
        raise ApiError(422, "pool port harus >= 1024 (hindari port sistem).")
    token = str(b.get("token") or "").strip()
    if token and not TOKEN_RE.fullmatch(token):
        raise ApiError(422, "token harus hex 16-96 karakter (dari `vpsnat node init`).")
    node = db.node_add(name=name, url=url, wan_ip=wan, port_min=lo, port_max=hi, token=token,
                       description=str(b.get("description") or "")[:120])
    app.store_audit_file(req.who, "node.add", name, "ok", f"url={url} pool={lo}-{hi}")
    return 201, {"ok": True, "node": node_view(node), "token": node.get("token", "")}


@route("GET", rf"/api/admin/nodes/{app.MID}", "admin")
def a_node_get(req, mid):
    node = app.node_get(mid)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    return {"ok": True, "node": node_view(node, db.allocations_stats().get(node["id"], {}))}


@route("DELETE", rf"/api/admin/nodes/{app.MID}", "admin")
def a_node_delete(req, mid):
    node = app.node_get(mid)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    try:
        db.node_delete(node["name"])
    except ValueError as exc:
        raise ApiError(409, str(exc)) from exc
    app.store_audit_file(req.who, "node.del", node["name"])
    return {"ok": True}


@route("POST", rf"/api/admin/nodes/{app.MID}/ping", "admin")
def a_node_ping(req, mid):
    node = app.node_get(mid, token=True)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    try:
        info = app.client_for(node["id"], timeout=8.0).system(timeout=8.0)
    except Exception as exc:  # noqa: BLE001
        db.node_set(node["name"], last_status="unreachable", last_error=str(exc)[:200])
        return {"ok": True, "online": False, "error": str(exc)}
    db.node_set(node["name"], last_seen=int(time.time()), last_status="online", last_error="",
                system_json=json.dumps(info, separators=(",", ":")))
    return {"ok": True, "online": True, "system": info}


@route("POST", rf"/api/admin/nodes/{app.MID}/token", "admin")
def a_node_token(req, mid):
    node = app.node_get(mid)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    token = db.node_rotate_token(node["name"])
    app.store_audit_file(req.who, "node.token.rotate", node["name"])
    return {"ok": True, "token": token}


@route("POST", rf"/api/admin/nodes/{app.MID}/maintenance", "admin")
def a_node_maintenance(req, mid):
    node = app.node_get(mid)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    flag = v_bool(req.body.get("maintenance"), "maintenance", not bool(node["maintenance"]))
    db.node_set(node["name"], maintenance=1 if flag else 0)
    app.store_audit_file(req.who, "node.maintenance", node["name"], "ok", f"on={int(flag)}")
    return {"ok": True, "maintenance": flag}


@route("POST", rf"/api/admin/nodes/{app.MID}/ports", "admin")
def a_node_ports(req, mid):
    """Perluas rentang pool port node (alokasi baru dibuat untuk port yang belum ada)."""
    node = app.node_get(mid)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    lo = v_int(req.body, "port_min", int(node["port_min"]), 1024, 65535)
    hi = v_int(req.body, "port_max", int(node["port_max"]), 1024, 65535)
    if hi < lo:
        raise ApiError(422, "port_max harus >= port_min.")
    with db.tx() as c:
        c.execute("UPDATE nodes SET port_min=?, port_max=? WHERE id=?", (lo, hi, node["id"]))
        c.executemany("INSERT OR IGNORE INTO allocations(node_id, port) VALUES(?, ?)",
                      [(node["id"], p) for p in range(lo, hi + 1)])
    app.store_audit_file(req.who, "node.pool", node["name"], "ok", f"{lo}-{hi}")
    return {"ok": True, "port_min": lo, "port_max": hi}


@route("POST", rf"/api/admin/nodes/{app.MID}/update", "admin")
def a_node_update(req, mid):
    """Ubah URL / WAN IP / keterangan node (mis. setelah node pindah IP)."""
    node = app.node_get(mid)
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    fields: dict = {}
    if req.body.get("url"):
        fields["url"] = normalize_url(req.body["url"])
    if req.body.get("wan_ip"):
        wan = str(req.body["wan_ip"]).strip()
        if len(wan.split(".")) != 4 or not all(p.isdigit() for p in wan.split(".")):
            raise ApiError(422, "wan_ip wajib IPv4.")
        fields["wan_ip"] = wan
    if "description" in req.body:
        fields["description"] = str(req.body["description"])[:120]
    if not fields:
        raise ApiError(422, "Tidak ada field yang diubah.")
    db.node_set(node["name"], **fields)
    app.store_audit_file(req.who, "node.update", node["name"], "ok", json.dumps(fields))
    return {"ok": True, "node": node_view(db.node_get(node["name"]) or node)}


@route("GET", "/api/admin/dashboard", "admin")
def a_dashboard(req):
    nodes = all_node_views()
    counts = db.servers_counts()
    return {
        "ok": True,
        "summary": {
            "nodes": len(nodes),
            "nodes_online": sum(1 for n in nodes if n["online"]),
            "servers": counts["total"],
            "running": counts["running"],
            "suspended": counts["suspended"],
            "cpu": counts["cpu"],
            "ram": counts["ram"],
            "disk": counts["disk"],
            "bw": counts["bw"],
            "ports_total": sum(n["ports_total"] for n in nodes),
            "ports_free": sum(n["ports_free"] for n in nodes),
        },
        "nodes": nodes,
        "limits": {"ports_min": PORTS_MIN, "ports_max": PORTS_MAX},
    }


@route("GET", "/api/admin/allocations", "admin")
def a_allocations(req):
    names = {n["id"]: n["name"] for n in db.nodes_all()}
    with db.read() as c:
        rows = c.execute(
            "SELECT a.node_id, a.port, a.server_id, s.name AS server FROM allocations a"
            " LEFT JOIN servers s ON s.id=a.server_id ORDER BY a.node_id, a.port"
        ).fetchall()
    return {
        "ok": True,
        "allocations": [
            {"node": names.get(r["node_id"], str(r["node_id"])), "port": r["port"], "server": r["server"]}
            for r in rows
        ],
    }


@route("POST", "/api/sync", "admin")
def a_sync(req):
    """Tarik status semua node + server dari node ke panel DB."""
    health = syncmod.node_health()
    changed = syncmod.sync_all(quiet=True)
    app.store_audit_file(req.who, "panel.sync", "-", "ok", f"servers={changed}")
    return {
        "ok": True,
        "servers_synced": changed,
        "nodes_online": sum(1 for v in health.values() if v.get("online")),
        "nodes": len(health),
        "output": f"{changed} server disinkronkan; {sum(1 for v in health.values() if v.get('online'))}/{len(health)} node online",
    }


app.page("/nodes")(lambda: "nodes.html")
