#!/usr/bin/env python3
"""Sinkronisasi panel ↔ node.

Panel menyimpan metadata (nama, kredensial, port SSH, expiry); node menyimpan
kenyataan (state LXD, pemakaian bandwidth, alasan suspend). Modul ini menarik
kenyataan itu ke panel supaya UI dan API selalu menampilkan data yang benar.

  python3 sync.py              # sinkronkan semua server
  python3 sync.py <nama>       # sinkronkan satu server
  python3 sync.py --json       # keluarkan hasil sebagai JSON (untuk CLI)
"""
from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db  # noqa: E402
from nodeclient import NodeClient, NodeError  # noqa: E402

TERMINAL_STATES = ("MISSING",)


def client_for_node(node: dict) -> NodeClient:
    return NodeClient(str(node.get("url") or ""), str(node.get("token") or ""), timeout=20.0)


def _apply(server: dict, inst: dict) -> dict:
    """Bandingkan instance dari node dengan baris panel; kembalikan field yang berubah."""
    changes: dict[str, Any] = {}
    state = str(inst.get("state") or "UNKNOWN").upper()
    if state in TERMINAL_STATES:
        # Instance tidak ada di node: tanda supaya admin memutuskan (jangan hapus otomatis).
        changes["state"] = "MISSING"
    else:
        changes["state"] = state
    for field, src in (("suspended", "suspended"), ("reason", "reason"), ("cpu", "cpu"), ("ram", "ram"), ("disk", "disk")):
        value = inst.get(src)
        if value is None:
            continue
        if field in ("suspended",):
            value = 1 if value else 0
        if server.get(field) != value:
            changes[field] = value
    ports = inst.get("ports") or []
    if ports:
        ssh = next((p for p in ports if p.get("ssh")), None)
        if ssh and ssh.get("public") and server.get("ssh_port") != int(ssh["public"]):
            changes["ssh_port"] = int(ssh["public"])
    bw = inst.get("bw") or {}
    for field, src in (("bw_rx", "rx"), ("bw_tx", "tx")):
        if bw.get(src) is not None and int(bw.get(src) or 0) != int(server.get(field) or 0):
            changes[field] = int(bw.get(src) or 0)
    if bw.get("rate") is not None and float(bw.get("rate") or 0) != float(server.get("bw_rate") or 0):
        changes["bw_rate"] = float(bw.get("rate") or 0)
    if bw.get("quota") is not None and int(bw.get("quota") or 0) != int(server.get("bw_quota") or 0):
        changes["bw_quota"] = int(bw.get("quota") or 0)
    return changes


def sync_server(name: str, quiet: bool = False) -> dict | None:
    server = db.server_get(name)
    if server is None:
        return None
    node = db.node_get(int(server["node_id"]), with_token=True)
    if node is None:
        if not quiet:
            print(f"[!] {name}: node tidak ada di panel", file=sys.stderr)
        return None
    client = client_for_node(node)
    try:
        inst = client.instance(name)
    except NodeError as exc:
        db.server_update(name, state="UNREACHABLE", last_error=str(exc)[:200])
        if not quiet:
            print(f"[!] {name}: {exc}", file=sys.stderr)
        return None
    changes = _apply(server, inst)
    if inst.get("password") and inst["password"] != server.get("password"):
        # Reinstall/ubah password lewat node harus tercermin di panel agar login client tetap jalan.
        changes["password"] = inst["password"]
    changes["last_error"] = ""
    db.server_update(name, **changes)
    if not quiet:
        print(f"[+] {name}: {changes.get('state', server.get('state'))}")
    return changes


def forget_server(name: str) -> None:
    """Server dihapus di node; lepas alokasi portnya di panel."""
    server = db.server_get(name)
    if server is None:
        return
    db.allocations_release(int(server["id"]))
    db.server_delete(name)


def sync_all(quiet: bool = False) -> int:
    changed = 0
    cache: dict[int, tuple[dict, dict]] = {}
    for server in db.servers_all():
        nid = int(server["node_id"])
        if nid not in cache:
            node = db.node_get(nid, with_token=True)
            if node is None:
                continue
            client = client_for_node(node)
            try:
                cache[nid] = (node, client.instances_map())
            except NodeError as exc:
                cache[nid] = (node, {})
                if not quiet:
                    print(f"[!] node {node.get('name')}: {exc}", file=sys.stderr)
        node, mapping = cache[nid]
        inst = mapping.get(server["name"])
        if inst is None:
            db.server_update(server["name"], state="MISSING")
            continue
        changes = _apply(server, inst)
        changes["last_error"] = ""
        db.server_update(server["name"], **changes)
        changed += 1
    return changed


def node_health() -> dict[int, dict]:
    """Perbarui kolom last_seen / status tiap node di panel."""
    result = {}
    now = int(time.time())
    for node in db.nodes_all():
        full = db.node_get(node["id"], with_token=True) or node
        client = client_for_node(full)
        try:
            info = client.system(timeout=8.0)
            db.node_set(
                node["name"],
                last_seen=now,
                last_status="online",
                last_error="",
                wan_ip=str(info.get("public_ip") or node["wan_ip"]) or node["wan_ip"],
                system_json=json.dumps(info, separators=(",", ":")),
            )
            result[node["id"]] = {"online": True, "system": info}
        except NodeError as exc:
            db.node_set(node["name"], last_status="offline" if not node["last_seen"] else "unreachable", last_error=str(exc)[:200])
            result[node["id"]] = {"online": False, "error": str(exc)}
    return result


def main(argv: list[str]) -> int:
    import argparse

    p = argparse.ArgumentParser(prog="sync", description="sinkronkan panel dengan node")
    p.add_argument("name", nargs="?", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--nodes", action="store_true", help="hanya perbarui status node")
    p.add_argument("--quiet", action="store_true")
    a = p.parse_args(argv)
    db.connect().close()

    if a.nodes:
        res = node_health()
        print(json.dumps(res, indent=2, ensure_ascii=False) if a.json else f"[i] {sum(1 for v in res.values() if v['online'])}/{len(res)} node online")
        return 0
    if a.name:
        out = sync_server(a.name, quiet=a.quiet)
        if a.json:
            print(json.dumps(out, indent=2, ensure_ascii=False))
        return 0 if out is not None else 1
    health = node_health()
    n = sync_all(quiet=a.quiet)
    if a.json:
        print(json.dumps({"servers_synced": n, "nodes": health}, indent=2, ensure_ascii=False))
    else:
        print(f"[i] {n} server disinkronkan; {sum(1 for v in health.values() if v['online'])}/{len(health)} node online")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
