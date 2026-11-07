#!/usr/bin/env python3
"""Impor VPS yang sudah ada ke panel DB.

Dipakai saat upgrade dari v3 (satu host) atau saat node yang sudah berisi VPS
didaftarkan ke panel. Dua sumber:

  * `--from URL --token T` : baca daftar instance dari agent node (disarankan)
  * tanpa opsi              : baca /etc/vpsnat/vps.db lokal (peran `both`)

Yang dibuat: baris `servers` + `allocations` di panel DB. Tidak ada yang dihapus
dan tidak ada perubahan pada node.

    python3 panel/import.py --node node-1 [--from http://IP:8788 --token T] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import db  # noqa: E402
from nodeclient import NodeClient, NodeError  # noqa: E402

NODE_DB = os.environ.get("VPSNAT_NODE_DB", "/etc/vpsnat/vps.db")
COLS = (
    "name ip ssh cpu ram disk ports password created backend expires owner suspended plan "
    "quota rx tx rate quota_susp high_since cpu_prev sample_ts bw_prev_rx bw_prev_tx reason"
).split()


def _int(value) -> int:
    try:
        return int(str(value).strip() or 0)
    except (TypeError, ValueError):
        return 0


def _float(value) -> float:
    try:
        return float(str(value).strip() or 0)
    except (TypeError, ValueError):
        return 0.0


def read_local_db(path: str) -> list[dict]:
    """Baca vps.db node (pipe-delimited 25 kolom)."""
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as exc:
        raise SystemExit(f"[x] Tidak bisa membaca {path}: {exc}") from exc
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("|")
        parts += [""] * (len(COLS) - len(parts))
        row = dict(zip(COLS, parts))
        ports = []
        ssh = _int(row["ssh"])
        for entry in (row["ports"] or "").split(","):
            bits = entry.split(":")
            if len(bits) == 3 and bits[1].isdigit():
                pub = int(bits[1])
                if pub not in ports:
                    ports.append(pub)
        if ssh and ssh not in ports:
            ports.insert(0, ssh)
        rows.append({
            "name": row["name"], "ssh_port": ssh, "password": row["password"] or "unknown",
            "cpu": _int(row["cpu"]) or 1, "ram": _int(row["ram"]) or 1024, "disk": _int(row["disk"]) or 10,
            "plan": row["plan"] or "shared", "backend": row["backend"] or "container",
            "expires": _int(row["expires"]), "owner": row["owner"] or "-",
            "suspended": _int(row["suspended"]), "reason": row["reason"] or "-",
            "bw_quota": _int(row["quota"]), "bw_rate": _float(row["rate"]),
            "bw_rx": _int(row["rx"]), "bw_tx": _int(row["tx"]),
            "created": row["created"] or time.strftime("%Y-%m-%d"),
            "state": "STOPPED" if _int(row["suspended"]) else "RUNNING",
            "ports": ports,
        })
    return rows


def read_agent(url: str, token: str) -> list[dict]:
    client = NodeClient(url, token, timeout=30.0)
    try:
        instances = client.instances()
    except NodeError as exc:
        raise SystemExit(f"[x] Gagal membaca instance dari node: {exc}") from exc
    rows = []
    for inst in instances:
        name = inst.get("name")
        if not name:
            continue
        detail = inst
        try:
            detail = client.instance(name) or inst
        except NodeError:
            pass
        ports = [int(p["public"]) for p in (detail.get("ports") or []) if p.get("public")]
        ssh = _int(detail.get("ssh"))
        if ssh and ssh not in ports:
            ports.insert(0, ssh)
        bw = detail.get("bw") or {}
        rows.append({
            "name": name, "ssh_port": ssh or (ports[0] if ports else 0),
            "password": detail.get("password") or "unknown",
            "cpu": _int(detail.get("cpu")) or 1, "ram": _int(detail.get("ram")) or 1024,
            "disk": _int(detail.get("disk")) or 10, "plan": detail.get("plan") or "shared",
            "backend": detail.get("backend") or "container", "expires": _int(detail.get("expires")),
            "owner": detail.get("owner") or "-", "suspended": 1 if detail.get("suspended") else 0,
            "reason": detail.get("reason") or "-", "bw_quota": _int(bw.get("quota")),
            "bw_rate": _float(bw.get("rate")), "bw_rx": _int(bw.get("rx")), "bw_tx": _int(bw.get("tx")),
            "created": detail.get("created") or time.strftime("%Y-%m-%d"),
            "state": "SUSPEND" if detail.get("suspended") else str(detail.get("state") or "UNKNOWN").upper(),
            "ports": ports,
        })
    return rows


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="panel-import", description="impor VPS yang sudah ada ke panel DB")
    p.add_argument("--node", default="", help="nama node di panel (default: satu-satunya node)")
    p.add_argument("--from", dest="url", default="", help="URL agent node (opsional)")
    p.add_argument("--token", default="", help="token agent (opsional, default dari panel DB)")
    p.add_argument("--db", default=NODE_DB, help="path vps.db node (mode lokal)")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)

    db.connect().close()
    nodes = db.nodes_all()
    if not nodes:
        print("[x] Belum ada node di panel. Daftarkan dulu: vpsnat node add ...", file=sys.stderr)
        return 1
    node = None
    if a.node:
        node = db.node_get(a.node)
        if not node:
            print(f"[x] Node '{a.node}' tidak ada di panel.", file=sys.stderr)
            return 1
    elif len(nodes) == 1:
        node = nodes[0]
    else:
        print("[x] Lebih dari satu node terdaftar; sebutkan --node <nama>.", file=sys.stderr)
        return 1

    if a.url:
        token = a.token or str((db.node_get(node["id"], with_token=True) or {}).get("token") or "")
        rows = read_agent(a.url, token)
        source = f"agent {a.url}"
    else:
        rows = read_local_db(a.db)
        source = a.db
    if not rows:
        print(f"[i] Tidak ada instance ditemukan di {source}.")
        return 0

    print(f"[i] Sumber: {source} · {len(rows)} instance · node panel: {node['name']}")
    imported = skipped = ports_added = 0
    for row in rows:
        if db.server_get(row["name"]):
            print(f"    lewat  {row['name']} (sudah ada di panel)")
            skipped += 1
            continue
        ports = [p for p in row["ports"] if 1024 <= p <= 65535]
        if not ports:
            print(f"    lewat  {row['name']} (tidak ada port publik valid)")
            skipped += 1
            continue
        if a.dry_run:
            print(f"    akan   {row['name']} ssh={row['ssh_port']} ports={ports}")
            imported += 1
            continue
        record = db.server_create({
            "uuid": secrets.token_hex(8), "name": row["name"], "node_id": node["id"],
            "owner": row["owner"], "plan": row["plan"], "backend": row["backend"],
            "image": "ubuntu22", "cpu": row["cpu"], "ram": row["ram"], "disk": row["disk"],
            "nesting": 1, "ssh_port": row["ssh_port"], "password": row["password"],
            "created": row["created"], "expires": row["expires"], "suspended": row["suspended"],
            "reason": row["reason"], "bw_quota": row["bw_quota"], "bw_rate": row["bw_rate"],
            "state": row["state"],
        })
        with db.tx() as c:
            for port in ports:
                c.execute("INSERT OR IGNORE INTO allocations(node_id, port) VALUES(?, ?)", (node["id"], port))
            for port in ports:
                c.execute(
                    "UPDATE allocations SET server_id=? WHERE node_id=? AND port=?",
                    (record["id"], node["id"], port),
                )
        db.server_update(row["name"], bw_rx=row["bw_rx"], bw_tx=row["bw_tx"])
        print(f"    impor  {row['name']} ssh={row['ssh_port']} ports={ports}")
        imported += 1
        ports_added += len(ports)

    verb = "akan diimpor" if a.dry_run else "diimpor"
    print(f"[+] {imported} instance {verb}, {skipped} dilewati, {ports_added} alokasi port ditulis.")
    if not a.dry_run and imported:
        print("[i] Verifikasi: vpsnat servers && vpsnat sync")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
