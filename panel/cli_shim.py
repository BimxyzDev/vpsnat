#!/usr/bin/env python3
"""Shim `vpsnat` untuk PANEL — menjalankan perintah gaya-CLI di control-plane.

Bot Telegram dulu memanggil binari CLI `vpsnat`. Di panel murni tidak ada LXD,
jadi perintah itu tidak berlaku. Modul ini menjawab kontrak yang sama
(`run(argv) -> (rc, teks)`) tetapi mengambil data dari panel DB dan mengirim
operasi mesin ke node lewat agent.

Dipakai `panel/bot.py` saat host berperan panel. Dengan begini logika bot tidak
perlu ditulis ulang: ia tetap "memanggil CLI", hanya backend-nya panel.
"""
from __future__ import annotations

import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import db  # noqa: E402
import jobs  # noqa: E402
import sync as syncmod  # noqa: E402
from nodeclient import NodeClient, NodeError  # noqa: E402


# ------------------------------------------------------------------ helpers
def _node(nid: int) -> dict | None:
    return db.node_get(int(nid), with_token=True)


def _client(server: dict) -> NodeClient:
    node = _node(int(server["node_id"]))
    if not node:
        raise NodeError("node tidak ada di panel")
    return NodeClient(str(node.get("url") or ""), str(node.get("token") or ""), timeout=60.0)


def _fmt_bytes(b) -> str:
    b = float(b or 0)
    for unit, size in (("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)):
        if b >= size:
            return f"{b / size:.2f} {unit}"
    return f"{int(b)} B"


def _fmt_time(ts) -> str:
    if not ts:
        return "tanpa expired"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts)))


def _node_name(nid) -> str:
    node = db.node_get(int(nid))
    return str((node or {}).get("name") or f"#{nid}")


def _wan(nid) -> str:
    node = db.node_get(int(nid))
    return str((node or {}).get("wan_ip") or "-")


def _find(name: str) -> dict | None:
    return db.server_get(name)


def _server_line(s: dict) -> str:
    state = "SUSPEND" if s["suspended"] else s["state"]
    bw = int(s["bw_rx"]) + int(s["bw_tx"])
    quota = int(s["bw_quota"])
    bw_s = f"{_fmt_bytes(bw)}/{_fmt_bytes(quota)}" if quota else f"{_fmt_bytes(bw)}/∞"
    return (
        f"{s['name']:<14} {(_node_name(s['node_id']))[:10]:<10} {s['plan']:<10} {state:<10} "
        f"{_wan(s['node_id']):<16} {s['cpu']:<4} {s['ram']}M  {s['disk']}G  {s['ssh_port']:<7} {bw_s}"
    )


def _info_text(s: dict, with_password: bool = False) -> str:
    ports = db.allocations_of(int(s["id"]))
    ssh = int(s["ssh_port"])
    lines = [
        f"=== {s['name']} ===",
        f"Node         : {_node_name(s['node_id'])}",
        f"Tipe layanan : {s['plan']}",
        f"Backend      : {s['backend']} ({s['image']})",
        f"Status       : {'SUSPEND (' + s['reason'] + ')' if s['suspended'] else s['state']}",
        f"Spesifikasi  : {s['cpu']} CPU / {s['ram']} MB RAM / {s['disk']} GB Disk",
        f"Dibuat       : {s['created']}",
        f"Expired      : {_fmt_time(s['expires'])}",
        f"Owner        : {s['owner']}",
        f"SSH          : ssh root@{_wan(s['node_id'])} -p {ssh}",
    ]
    if with_password:
        lines.append(f"Password     : {s['password']}")
    used = int(s["bw_rx"]) + int(s["bw_tx"])
    lines.append(f"Bandwidth    : {_fmt_bytes(used)} (RX {_fmt_bytes(s['bw_rx'])}, TX {_fmt_bytes(s['bw_tx'])})")
    lines.append("Port map     :")
    for p in ports:
        internal = 22 if p == ssh else p
        proto = "tcp" if p == ssh else "tcp+udp"
        lines.append(f"  {proto:<8} {_wan(s['node_id'])}:{p} -> {internal}")
    return "\n".join(lines)


def _run_job(kind: str, target: str, node_id: int, payload: dict | None = None, actor: str = "bot", wait: int = 900):
    """Buat job lalu tunggu sampai selesai (dipakai perintah bot yang memblokir)."""
    try:
        job = jobs.spawn(kind, target, node_id, actor, payload)
    except jobs.BusyError as exc:
        return 1, f"[x] {exc}"
    deadline = time.time() + wait
    while time.time() < deadline:
        row = db.job_get(job["id"]) or {}
        if row.get("status") != "running":
            ok = row.get("status") == "done"
            out = (row.get("output") or "").strip()
            if kind == "delete" and ok:
                syncmod.forget_server(target)
            elif ok:
                syncmod.sync_server(target, quiet=True)
            return (0 if ok else 1), out or ("[+] selesai" if ok else "[x] gagal")
        time.sleep(2)
    return 124, "[x] Timeout menunggu job selesai."


def _power(name: str, action: str):
    s = _find(name)
    if not s:
        return 1, f"[x] Server '{name}' tidak ditemukan."
    try:
        out = _client(s).power(name, action).get("output", "")
    except NodeError as exc:
        return 1, f"[x] {exc}"
    try:
        inst = _client(s).instance(name)
        db.server_update(name, state=str(inst.get("state") or "UNKNOWN").upper(),
                         suspended=1 if inst.get("suspended") else 0)
    except NodeError:
        pass
    return 0, out or f"[+] {action} OK"


# ------------------------------------------------------------------ dispatch
def run(argv: list[str], env: dict | None = None) -> tuple[int, str]:
    """Titik masuk: kembalikan (rc, teks) seperti CLI Bash."""
    env = env or {}
    if not argv or argv[0] in ("help", "-h", "--help"):
        return 0, help_text()
    cmd, args = argv[0], argv[1:]
    db.connect().close()

    try:
        return _dispatch(cmd, args, env)
    except NodeError as exc:
        return 1, f"[x] Node: {exc}"
    except Exception as exc:  # noqa: BLE001
        return 1, f"[x] Panel: {type(exc).__name__}: {exc}"


def _dispatch(cmd: str, args: list[str], env: dict) -> tuple[int, str]:
    # --- daftar & info -----------------------------------------------------
    if cmd in ("list", "ls"):
        rows = db.servers_all()
        if not rows:
            return 0, "(kosong)"
        head = (
            f"{'NAMA':<14} {'NODE':<10} {'PLAN':<10} {'STATE':<10} {'IP':<16} "
            f"{'CPU':<4} {'RAM':<6} {'DISK':<4} {'SSH':<7} BW"
        )
        return 0, "\n".join([head, "-" * 118] + [_server_line(s) for s in rows])

    if cmd == "info":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        try:
            syncmod.sync_server(name, quiet=True)
            s = _find(name) or s
        except Exception:  # noqa: BLE001
            pass
        return 0, _info_text(s, with_password=True)

    if cmd == "host":
        nodes = db.nodes_all()
        counts = db.servers_counts()
        out = ["=== Panel ==="]
        out.append(f"Brand        : {db.setting('brand', 'VPSNAT')}")
        out.append(f"Node         : {len(nodes)} ({sum(1 for n in nodes if n['last_seen'] and time.time() - n['last_seen'] < 120)} online)")
        out.append(f"Server       : {counts['total']} total · {counts['running']} running · {counts['suspended']} suspend")
        out.append("")
        out.append(f"{'NAMA':<14} {'WAN IP':<16} {'POOL':<14} {'SERVER':<7} STATUS")
        out.append("-" * 70)
        alloc = db.allocations_stats()
        for n in nodes:
            st = alloc.get(n["id"], {"total": 0, "free": 0})
            online = "online" if n["last_seen"] and time.time() - n["last_seen"] < 120 else (n["last_status"] or "offline")
            out.append(f"{n['name']:<14} {n['wan_ip']:<16} {str(n['port_min']) + '-' + str(n['port_max']):<14} "
                       f"{st['total'] - st['free']:<7} {online}")
        return 0, "\n".join(out)

    if cmd == "nodes":
        if args and args[0] == "list":
            nodes = db.nodes_all()
            return 0, "\n".join([f"{'NAMA':<16} {'WAN IP':<16} {'URL':<30} STATUS"] + ["-" * 80] +
                                [f"{n['name']:<16} {n['wan_ip']:<16} {n['url']:<30} {n['last_status']}" for n in nodes])
        return run(["host"])

    if cmd == "stats":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        try:
            res = _client(s).resources(name)
        except NodeError as exc:
            return 1, f"[x] {exc}"
        out = [
            f"=== {name} ===",
            f"State        : {res.get('state')}",
            f"CPU          : {res['cpu']['pct']}% dari {res['cpu']['cores']} core",
            f"RAM          : {_fmt_bytes(res['ram']['used'])} / {_fmt_bytes(res['ram']['limit'])} ({res['ram']['pct']}%)",
            f"Disk         : {_fmt_bytes(res['disk']['used'])} / {_fmt_bytes(res['disk']['limit'])} ({res['disk']['pct']}%)",
            f"Network      : RX {_fmt_bytes(res['net']['rx'])} · TX {_fmt_bytes(res['net']['tx'])}",
            f"Proses       : {res['procs']}",
        ]
        return 0, "\n".join(out)

    if cmd == "expiring":
        days = int(args[0]) if args and str(args[0]).isdigit() else 7
        limit = time.time() + days * 86400
        rows = [s for s in db.servers_all() if s["expires"] and s["expires"] <= limit]
        if not rows:
            return 0, f"(tidak ada server yang expired dalam {days} hari)"
        return 0, "\n".join([f"{'NAMA':<16} {'EXPIRED':<18} {'OWNER':<16} NODE"] + ["-" * 66] +
                            [f"{s['name']:<16} {_fmt_time(s['expires']):<18} {s['owner']:<16} {_node_name(s['node_id'])}" for s in rows])

    if cmd == "settings":
        if args and args[0] == "show":
            vals = db.settings_all()
            return 0, "\n".join(f"{k:<24} = {v}" for k, v in sorted(vals.items()))
        if args and args[0] == "set" and len(args) >= 3:
            db.setting_set(args[1].replace("-", "_"), args[2])
            return 0, f"[+] {args[1]} = {args[2]}"
        return 0, "\n".join(f"{k:<24} = {v}" for k, v in sorted(db.settings_all().items()))

    if cmd == "port-list":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        ssh = int(s["ssh_port"])
        out = [f"Port forward {name} ({_node_name(s['node_id'])})"]
        for p in db.allocations_of(int(s["id"])):
            internal = 22 if p == ssh else p
            proto = "tcp" if p == ssh else "tcp+udp"
            out.append(f"  {proto:<8} {_wan(s['node_id'])}:{p} -> {internal}")
        return 0, "\n".join(out)

    if cmd == "bandwidth":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        sub = args[1] if len(args) > 1 else "show"
        if sub == "show":
            used = int(s["bw_rx"]) + int(s["bw_tx"])
            quota = int(s["bw_quota"])
            pct = f"{used / quota * 100:.1f}%" if quota else "-"
            return 0, (f"Kuota     : {_fmt_bytes(quota) if quota else 'tanpa batas'}\n"
                       f"Terpakai  : {_fmt_bytes(used)} ({pct})\n"
                       f"RX        : {_fmt_bytes(s['bw_rx'])}\nTX        : {_fmt_bytes(s['bw_tx'])}\n"
                       f"Rate      : {s['bw_rate']} Mbps")
        if sub == "reset":
            out = _client(s).bandwidth(name, "reset").get("output", "")
            db.server_update(name, bw_rx=0, bw_tx=0)
            return 0, out or "[+] counter direset"
        if sub == "set" and len(args) >= 4:
            quota, rate = args[2], args[3]
            out = _client(s).bandwidth(name, "set", quota, rate).get("output", "")
            db.server_update(name, bw_quota=int(float(quota) * 1e9), bw_rate=float(rate))
            return 0, out or f"[+] kuota {quota} GB, rate {rate} Mbps"
        if sub == "limit" and len(args) >= 3:
            rate = args[2]
            out = _client(s).bandwidth(name, "limit", 0, rate).get("output", "")
            db.server_update(name, bw_rate=float(rate))
            return 0, out or f"[+] rate {rate} Mbps"
        return 1, "[x] Pakai: bandwidth <nama> [show|set <gb> <mbps>|limit <mbps>|reset]"

    if cmd == "snapshot":
        name = args[0] if args else ""
        action = args[1] if len(args) > 1 else "list"
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        return 1, f"[x] Snapshot dikelola langsung di node: ssh ke {_node_name(s['node_id'])} lalu `vpsnat snapshot {name} {action}`"

    # --- operasi yang mengubah keadaan ------------------------------------
    if cmd in ("start", "stop", "restart", "suspend", "unsuspend"):
        if not args:
            return 1, f"[x] Pakai: {cmd} <nama>"
        return _power(args[0], cmd)

    if cmd == "delete":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        return _run_job("delete", name, int(s["node_id"]), actor="bot")

    if cmd == "reinstall":
        name = args[0] if args else ""
        image = env.get("IMG_KEY") or (args[1] if len(args) > 1 else "ubuntu22")
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        rc, out = _run_job("reinstall", name, int(s["node_id"]), {"image": image}, actor="bot", wait=1800)
        if rc == 0:
            db.server_update(name, image=image)
        return rc, out

    if cmd == "create":
        name = args[0] if args else env.get("NAME", "")
        if not name:
            return 1, "[x] Nama server wajib."
        if _find(name):
            return 1, f"[x] Server '{name}' sudah ada."
        ref = env.get("NODE_ID") or env.get("NODE") or ""
        if ref:
            node = db.node_get(int(ref)) if str(ref).isdigit() else db.node_get(str(ref))
        else:
            online = [n for n in db.nodes_all() if n["maintenance"] == 0 and n["last_seen"] and time.time() - n["last_seen"] < 120]
            node = online[0] if online else None
        if not node:
            return 1, "[x] Tidak ada node online. Daftarkan node lebih dahulu."
        raw_ports = env.get("NPORTS") or (args[1] if len(args) > 1 else "") or "3"
        nports = int(raw_ports) if str(raw_ports).isdigit() else 3
        try:
            ports = db.allocations_take(int(node["id"]), nports)
        except ValueError as exc:
            return 1, f"[x] {exc}"
        import secrets as _secrets
        password = env.get("PASS") or _secrets.token_urlsafe(12)
        payload = {
            "name": name, "image": env.get("IMG_KEY", "ubuntu22"),
            "cpu": int(env.get("CPU") or 1), "ram": int(env.get("RAM") or 1024),
            "disk": int(env.get("DISK") or 10), "plan": env.get("PLAN_TYPE", "shared"),
            "backend": "vm" if str(env.get("VTYPE", "1")) == "2" else "container",
            "expire": env.get("EXPIRE", "0"), "owner": env.get("OWNER", "-"),
            "nesting": str(env.get("NESTING", "y")).lower() == "y",
            "password": password, "ports": ports, "ssh_port": ports[0],
        }
        if env.get("BW_QUOTA_GB") not in (None, ""):
            payload["bw_quota_gb"] = env["BW_QUOTA_GB"]
        if env.get("BW_LIMIT_MBIT") not in (None, ""):
            payload["bw_rate_mbit"] = env["BW_LIMIT_MBIT"]
        row = db.server_create({
            "name": name, "node_id": node["id"], "owner": payload["owner"], "plan": payload["plan"],
            "backend": payload["backend"], "image": payload["image"], "cpu": payload["cpu"],
            "ram": payload["ram"], "disk": payload["disk"], "nesting": payload["nesting"],
            "ssh_port": ports[0], "password": password, "state": "CREATING",
        })
        db.allocations_assign(int(node["id"]), ports, int(row["id"]))
        rc, out = _run_job("create", name, int(node["id"]), payload, actor="bot", wait=1800)
        if rc != 0:
            return rc, out
        fresh = _find(name) or row
        return 0, out + "\n" + _info_text(fresh, with_password=True)

    if cmd == "passwd":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        pw = env.get("PASS") or ""
        out = _client(s).password(name, pw or None)
        final = str(out.get("password") or "")
        if final:
            db.server_update(name, password=final)
        return 0, (out.get("output", "") + f"\nPassword {name}: {final}").strip()

    if cmd == "resize":
        name = args[0] if args else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        cpu = int(env.get("CPU") or s["cpu"])
        ram = int(env.get("RAM") or s["ram"])
        disk = int(env.get("DISK") or s["disk"])
        out = _client(s).resize(name, cpu, ram, disk).get("output", "")
        db.server_update(name, cpu=cpu, ram=ram, disk=disk)
        return 0, out or f"[+] {name}: {cpu} CPU / {ram} MB / {disk} GB"

    if cmd == "renew":
        name = args[0] if args else ""
        dur = args[1] if len(args) > 1 else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        out = _client(s).expire(name, dur).get("output", "")
        epoch = _epoch(dur) or 0
        db.server_update(name, expires=epoch)
        return 0, out or f"[+] {name} diperpanjang {dur}"

    if cmd == "set-expire":
        name = args[0] if args else ""
        val = args[1] if len(args) > 1 else "0"
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        out = _client(s).expire(name, val).get("output", "")
        db.server_update(name, expires=_epoch(val) or 0)
        return 0, out or f"[+] expire {name}: {_fmt_time(_epoch(val))}"

    if cmd == "set-owner":
        name = args[0] if args else ""
        owner = args[1] if len(args) > 1 else "-"
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        out = _client(s).owner(name, owner).get("output", "")
        db.server_update(name, owner=owner)
        return 0, out or f"[+] owner {name} = {owner}"

    if cmd == "set-type":
        name = args[0] if args else ""
        plan = args[1] if len(args) > 1 else "shared"
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        out = _client(s).plan(name, plan).get("output", "")
        db.server_update(name, plan=plan)
        return 0, out or f"[+] tipe {name} = {plan}"

    if cmd == "port-add":
        name = args[0] if args else ""
        proto = args[1] if len(args) > 1 else "tcp"
        count = int(args[2]) if len(args) > 2 and str(args[2]).isdigit() else 1
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        try:
            ports = db.allocations_take(int(s["node_id"]), count)
        except ValueError as exc:
            return 1, f"[x] {exc}"
        out = _client(s).ports_add(name, proto, count, ports).get("output", "")
        db.allocations_assign(int(s["node_id"]), ports, int(s["id"]))
        return 0, out or f"[+] {count} port ditambahkan: {ports}"

    if cmd == "port-del":
        name = args[0] if args else ""
        port = args[1] if len(args) > 1 else ""
        s = _find(name)
        if not s:
            return 1, f"[x] Server '{name}' tidak ditemukan."
        out = _client(s).ports_del(name, int(port)).get("output", "")
        with db.tx() as c:
            c.execute("UPDATE allocations SET server_id=NULL WHERE server_id=? AND port=?", (int(s["id"]), int(port)))
        return 0, out or f"[+] port {port} dihapus"

    if cmd == "sync":
        health = syncmod.node_health()
        changed = syncmod.sync_all(quiet=True)
        return 0, (f"[+] {changed} server disinkronkan; "
                   f"{sum(1 for v in health.values() if v.get('online'))}/{len(health)} node online")

    if cmd == "grace":
        if args:
            db.setting_set("grace_days", str(args[0]))
            return 0, f"[+] grace = {args[0]} hari"
        return 0, f"grace = {db.setting('grace_days', '3')} hari"

    if cmd == "publicip":
        return 0, "Public IP ditentukan per node (kolom WAN IP). Ubah dengan: vpsnat node show <nama>"

    if cmd == "clone":
        return 1, "[x] Clone belum didukung dari panel; jalankan di node: vpsnat clone <nama>"

    if cmd == "backup":
        return 1, "[x] Backup dijalankan di node (butuh LXD): vpsnat backup <nama>"

    return 1, f"[x] Perintah '{cmd}' tidak tersedia dari panel. Lihat: vpsnat help"


def _epoch(value: str) -> int:
    """Ubah durasi/tanggal ke epoch detik (0 = tanpa expired)."""
    import datetime as dt
    import re as _re

    value = str(value or "0").strip().lower()
    if value in ("", "0", "never"):
        return 0
    if value.isdigit() and len(value) >= 9:
        return int(value)
    m = _re.fullmatch(r"([0-9]+)([hdwm])", value)
    now = dt.datetime.now()
    if m:
        num, unit = int(m.group(1)), m.group(2)
        delta = {"h": dt.timedelta(hours=num), "d": dt.timedelta(days=num),
                 "w": dt.timedelta(weeks=num), "m": dt.timedelta(days=num * 30)}[unit]
        return int((now + delta).timestamp())
    try:
        return int(dt.datetime.strptime(value, "%Y-%m-%d").replace(hour=23, minute=59, second=59).timestamp())
    except ValueError:
        return 0


def help_text() -> str:
    return ("vpsnat (panel) — perintah tersedia:\n"
            "  list, info <nama>, host, nodes [list], stats <nama>, expiring [hari]\n"
            "  create, delete, reinstall, start|stop|restart|suspend|unsuspend <nama>\n"
            "  passwd, resize, renew, set-expire, set-owner, set-type\n"
            "  port-add, port-del, port-list, bandwidth <nama> [show|set|limit|reset]\n"
            "  settings [show|set], sync, grace, publicip")


if __name__ == "__main__":  # pragma: no cover
    rc, out = run(sys.argv[1:])
    print(out)
    sys.exit(rc)
