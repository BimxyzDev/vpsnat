#!/usr/bin/env python3
"""Panel web: endpoint server (VPS client) — admin dan sisi client.

Semua operasi yang menyentuh mesin client dikirim ke NODE lewat agent:
  * operasi panjang (create/delete/reinstall) → job
  * operasi cepat (power, resize, password, bandwidth, port) → panggilan langsung

Data (nama, kredensial, IP + port SSH, alokasi) dimiliki PANEL. Port dialokasikan
di sini SEBELUM node membuat instance, sehingga satu port tidak akan pernah
dipakai dua client.
"""
from __future__ import annotations

import secrets

import app
import db
import jobs
from app import (
    IMAGES, PORTS_MAX, PORTS_MIN, ApiError, route, setting_int, v_choice, v_dur, v_int,
    v_name, v_num, v_owner, v_pass,
)
from pages.core_api import (  # noqa: E402
    expire_epoch, need_server, node_call, node_for, pull_state, server_view,
)

__all__ = ["a_meta", "a_list", "a_create", "a_get", "a_delete", "a_power", "a_reinstall",
           "a_password", "a_resize", "a_expire", "a_owner", "a_plan", "a_bandwidth",
           "a_port_add", "a_port_del", "a_resources", "me", "me_resources", "me_action",
           "me_passwd", "me_reinstall", "me_jobs"]


def gen_password(length: int = 16) -> str:
    """Password root yang memenuhi aturan safe_password CLI (tanpa spasi/newline)."""
    alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789@%^*_+=.,:;!?~-"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def allocate_ports(node_id: int, count: int) -> list[int]:
    try:
        return db.allocations_take(int(node_id), count)
    except ValueError as exc:
        raise ApiError(422, str(exc)) from exc


@route("GET", "/api/meta")
def a_meta(req):
    """Pilihan yang dipakai form UI, plus daftar node (admin saja)."""
    is_admin = (req.auth or {}).get("role") == "admin"
    return {
        "ok": True,
        "images": list(IMAGES),
        "plans": ["shared", "dedicated"],
        "backends": ["container", "vm"],
        "limits": {"ports_min": PORTS_MIN, "ports_max": PORTS_MAX, "cpu": [1, 128], "ram": [128, 1048576], "disk": [1, 10000]},
        "defaults": {
            "ports": setting_int("default_ports", 3),
            "quota_gb": setting_int("default_quota_gb", 0),
            "rate_mbit": setting_int("default_rate_mbit", 0),
        },
        "nodes": [
            {"id": n["id"], "name": n["name"], "wan_ip": n["wan_ip"], "online": app.node_online(n["id"]),
             "port_min": n["port_min"], "port_max": n["port_max"], "maintenance": bool(n["maintenance"])}
            for n in db.nodes_all()
        ] if is_admin else [],
    }


# ---------------------------------------------------------------- admin: daftar
@route("GET", "/api/admin/servers", "admin")
def a_list(req):
    nodes = {n["id"]: n for n in db.nodes_all()}
    return {
        "ok": True,
        "servers": [server_view(r, nodes.get(r["node_id"])) for r in db.servers_all()],
        "limits": {"ports_min": PORTS_MIN, "ports_max": PORTS_MAX},
    }


# ---------------------------------------------------------------- admin: buat
@route("POST", "/api/admin/servers", "admin")
def a_create(req):
    b = req.body
    name = v_name(b.get("name"))
    if db.server_get(name):
        raise ApiError(409, "Server dengan nama itu sudah ada.")

    ref = b.get("node_id", b.get("node"))
    if ref in (None, "", 0, "0"):
        online = [n for n in db.nodes_all() if app.node_online(n["id"]) and not n["maintenance"]]
        if not online:
            raise ApiError(503, "Tidak ada node online. Daftarkan atau periksa node lebih dahulu.")
        node = online[0]
    else:
        node = db.node_get(int(ref)) if str(ref).isdigit() else db.node_get(str(ref))
    if not node:
        raise ApiError(404, "Node tidak ditemukan.")
    if node["maintenance"]:
        raise ApiError(409, f"Node '{node['name']}' sedang maintenance.")
    if not app.node_online(int(node["id"])):
        raise ApiError(503, f"Node '{node['name']}' tidak terhubung.")

    nports = v_int(b, "ports", setting_int("default_ports", 3), PORTS_MIN, PORTS_MAX)
    ports = allocate_ports(int(node["id"]), nports)
    payload = {
        "name": name,
        "image": v_choice(b.get("image", "ubuntu22"), IMAGES, "image"),
        "cpu": v_int(b, "cpu", 1, 1, 128),
        "ram": v_int(b, "ram", 1024, 128, 1048576),
        "disk": v_int(b, "disk", 10, 1, 10000),
        "plan": v_choice(b.get("plan", "shared"), ("shared", "dedicated"), "plan"),
        "backend": v_choice(b.get("backend", "container"), ("container", "vm"), "backend"),
        "expire": v_dur(b.get("expire", "0")),
        "owner": v_owner(b.get("owner")),
        "nesting": app.v_bool(b.get("nesting"), "nesting", True),
        "password": v_pass(b.get("password")),
        "ports": ports,
        "ssh_port": ports[0],
    }
    if b.get("bw_quota_gb") not in (None, ""):
        payload["bw_quota_gb"] = v_num(b["bw_quota_gb"], "bw_quota_gb", 1_000_000)
    if b.get("bw_rate_mbit") not in (None, ""):
        payload["bw_rate_mbit"] = v_num(b["bw_rate_mbit"], "bw_rate_mbit", 100_000)

    password = payload["password"] or gen_password()
    payload["password"] = password
    row = db.server_create({
        "name": name, "node_id": node["id"], "owner": payload["owner"], "plan": payload["plan"],
        "backend": payload["backend"], "image": payload["image"], "cpu": payload["cpu"],
        "ram": payload["ram"], "disk": payload["disk"], "nesting": payload["nesting"],
        "ssh_port": ports[0], "password": password,
        "expires": expire_epoch(payload["expire"]), "state": "CREATING",
    })
    db.allocations_assign(int(node["id"]), ports, int(row["id"]))
    job = jobs.spawn("create", name, int(node["id"]), req.who, payload)
    app.store_audit_file(req.who, "server.create", name, "ok",
                         f"node={node['name']} cpu={payload['cpu']} ram={payload['ram']} ports={ports}")
    return 202, {"ok": True, "job": job["id"], "server": server_view(row, node, with_password=True)}


# ---------------------------------------------------------------- admin: satu server
@route("GET", rf"/api/admin/servers/{app.NAME}", "admin")
def a_get(req, name):
    pull_state(need_server(name), quiet=True)
    return {"ok": True, "server": server_view(need_server(name), with_password=True)}


@route("DELETE", rf"/api/admin/servers/{app.NAME}", "admin")
def a_delete(req, name):
    row = need_server(name)
    node = node_for(row)
    job = jobs.spawn("delete", name, int(node["id"]), req.who)
    app.store_audit_file(req.who, "server.delete", name, "ok", f"node={node['name']}")
    return 202, {"ok": True, "job": job["id"]}


@route("POST", rf"/api/admin/servers/{app.NAME}/power", "admin")
def a_power(req, name):
    row = need_server(name)
    act = v_choice(req.body.get("action"), ("start", "stop", "restart", "suspend", "unsuspend"), "action")
    out = node_call(row, "power", name, act)
    pull_state(row, quiet=True)
    app.store_audit_file(req.who, f"server.{act}", name)
    return {"ok": True, "output": out.get("output", "")}


@route("POST", rf"/api/admin/servers/{app.NAME}/reinstall", "admin")
def a_reinstall(req, name):
    row = need_server(name)
    node = node_for(row)
    image = v_choice(req.body.get("image", "ubuntu22"), IMAGES, "image")
    job = jobs.spawn("reinstall", name, int(node["id"]), req.who, {"image": image})
    db.server_update(name, image=image)
    app.store_audit_file(req.who, "server.reinstall", name, "ok", f"image={image}")
    return 202, {"ok": True, "job": job["id"]}


@route("POST", rf"/api/admin/servers/{app.NAME}/password", "admin")
def a_password(req, name):
    row = need_server(name)
    pw = v_pass(req.body.get("password"))
    out = node_call(row, "password", name, pw)
    fresh = need_server(name)
    # Panel memegang kredensial: pakai password dari node (bila acak) lalu simpan.
    final = str(out.get("password") or fresh["password"] or "")
    if final and final != fresh["password"]:
        db.server_update(name, password=final)
    app.store_audit_file(req.who, "server.passwd", name)
    return {"ok": True, "output": out.get("output", ""), "password": final}


@route("POST", rf"/api/admin/servers/{app.NAME}/resize", "admin")
def a_resize(req, name):
    row = need_server(name)
    cpu = v_int(req.body, "cpu", int(row["cpu"]), 1, 128)
    ram = v_int(req.body, "ram", int(row["ram"]), 128, 1048576)
    disk = v_int(req.body, "disk", int(row["disk"]), int(row["disk"]), 10000)
    out = node_call(row, "resize", name, cpu, ram, disk)
    db.server_update(name, cpu=cpu, ram=ram, disk=disk)
    app.store_audit_file(req.who, "server.resize", name, "ok", f"cpu={cpu} ram={ram} disk={disk}")
    return {"ok": True, "output": out.get("output", "")}


@route("POST", rf"/api/admin/servers/{app.NAME}/expire", "admin")
def a_expire(req, name):
    row = need_server(name)
    rel = str(req.body.get("relative", "")).lower() in ("1", "true", "yes")
    value = v_dur(req.body.get("value", "0"), relative=rel) if rel else v_dur(req.body.get("value", "0"))
    out = node_call(row, "expire", name, value)
    db.server_update(name, expires=expire_epoch(value))
    app.store_audit_file(req.who, "server.expire", name, "ok", f"value={value}")
    return {"ok": True, "output": out.get("output", ""), "expires": expire_epoch(value)}


@route("POST", rf"/api/admin/servers/{app.NAME}/owner", "admin")
def a_owner(req, name):
    row = need_server(name)
    owner = v_owner(req.body.get("owner"))
    out = node_call(row, "owner", name, owner)
    db.server_update(name, owner=owner)
    app.store_audit_file(req.who, "server.owner", name, "ok", f"owner={owner}")
    return {"ok": True, "output": out.get("output", "")}


@route("POST", rf"/api/admin/servers/{app.NAME}/plan", "admin")
def a_plan(req, name):
    row = need_server(name)
    plan = v_choice(req.body.get("plan"), ("shared", "dedicated"), "plan")
    out = node_call(row, "plan", name, plan)
    db.server_update(name, plan=plan)
    app.store_audit_file(req.who, "server.plan", name, "ok", f"plan={plan}")
    return {"ok": True, "output": out.get("output", "")}


@route("POST", rf"/api/admin/servers/{app.NAME}/bandwidth", "admin")
def a_bandwidth(req, name):
    row = need_server(name)
    act = v_choice(req.body.get("action"), ("set", "limit", "reset"), "action")
    quota = v_num(req.body.get("quota_gb", 0), "quota_gb", 1_000_000)
    rate = v_num(req.body.get("rate_mbit", 0), "rate_mbit", 100_000)
    out = node_call(row, "bandwidth", name, act, quota, rate)
    if act in ("set", "limit"):
        db.server_update(name, bw_rate=float(rate))
    if act == "set":
        db.server_update(name, bw_quota=int(float(quota) * 1_000_000_000))
    if act == "reset":
        db.server_update(name, bw_rx=0, bw_tx=0)
    app.store_audit_file(req.who, "server.bandwidth", name, "ok", f"action={act} quota={quota} rate={rate}")
    return {"ok": True, "output": out.get("output", "")}


@route("POST", rf"/api/admin/servers/{app.NAME}/ports", "admin")
def a_port_add(req, name):
    row = need_server(name)
    proto = v_choice(req.body.get("proto", "tcp"), ("tcp", "udp", "both"), "proto")
    count = v_int(req.body, "count", 1, 1, 500)
    ports = allocate_ports(int(row["node_id"]), count)
    out = node_call(row, "ports_add", name, proto, count, ports)
    db.allocations_assign(int(row["node_id"]), ports, int(row["id"]))
    app.store_audit_file(req.who, "server.port.add", name, "ok", f"proto={proto} ports={ports}")
    return {"ok": True, "output": out.get("output", ""), "ports": ports}


@route("DELETE", rf"/api/admin/servers/{app.NAME}/ports/(?P<port>[0-9]{{1,5}})", "admin")
def a_port_del(req, name, port):
    row = need_server(name)
    pnum = int(port)
    if pnum == int(row["ssh_port"]):
        raise ApiError(422, "Port SSH tidak bisa dihapus.")
    if pnum not in db.allocations_of(int(row["id"])):
        raise ApiError(404, f"Port {pnum} bukan milik server ini.")
    out = node_call(row, "ports_del", name, pnum)
    with db.tx() as c:
        c.execute("UPDATE allocations SET server_id=NULL WHERE server_id=? AND port=?", (int(row["id"]), pnum))
    app.store_audit_file(req.who, "server.port.del", name, "ok", f"port={pnum}")
    return {"ok": True, "output": out.get("output", "")}


@route("GET", rf"/api/admin/servers/{app.NAME}/resources", "admin")
def a_resources(req, name):
    row = need_server(name)
    if not app.node_online(int(row["node_id"])):
        raise ApiError(503, "Node tidak terhubung; resource live tidak tersedia.")
    return {"ok": True, "res": node_call(row, "resources", name)}


# ---------------------------------------------------------------- sisi client
@route("GET", "/api/me", "user")
def me(req):
    pull_state(need_server(req.auth["name"]), quiet=True)
    row = need_server(req.auth["name"])
    view = server_view(row, with_password=True)
    return {"ok": True, "server": view, "vps": view}


@route("GET", "/api/me/resources", "user")
def me_resources(req):
    row = need_server(req.auth["name"])
    if not app.node_online(int(row["node_id"])):
        raise ApiError(503, "Node tidak terhubung; resource live tidak tersedia.")
    return {"ok": True, "res": node_call(row, "resources", row["name"])}


@route("POST", "/api/me/action", "user")
def me_action(req):
    row = need_server(req.auth["name"])
    act = v_choice(req.body.get("action"), ("start", "stop", "restart"), "action")
    out = node_call(row, "power", row["name"], act)
    pull_state(row, quiet=True)
    return {"ok": True, "output": out.get("output", "")}


@route("POST", "/api/me/passwd", "user")
def me_passwd(req):
    row = need_server(req.auth["name"])
    out = node_call(row, "password", row["name"], v_pass(req.body.get("password")))
    fresh = need_server(req.auth["name"])
    app.refresh_sessions(fresh["name"], req.h.session_token())
    return {"ok": True, "output": out.get("output", ""), "password": fresh["password"]}


@route("POST", "/api/me/reinstall", "user")
def me_reinstall(req):
    if setting_int("allow_user_reinstall", 0) != 1:
        raise ApiError(403, "Ubah OS dinonaktifkan. Hubungi admin.")
    row = need_server(req.auth["name"])
    node = node_for(row)
    image = v_choice(req.body.get("image", row["image"]), IMAGES, "image")
    job = jobs.spawn("reinstall", row["name"], int(node["id"]), req.who, {"image": image})
    return 202, {"ok": True, "job": job["id"]}


@route("GET", "/api/me/jobs", "user")
def me_jobs(req):
    items = [j for j in db.jobs_recent(30) if j["target"] == req.auth["name"]]
    return {"ok": True, "jobs": [jobs.view(j) for j in items]}
