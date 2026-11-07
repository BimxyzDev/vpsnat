#!/usr/bin/env python3
"""vpsnat panelctl — utilitas control-plane untuk dipanggil dari CLI Bash.

Semua perintah di sini bekerja pada panel DB (SQLite). Dipanggil oleh
`lib/panel/registry.sh`; tidak dimaksudkan sebagai API publik.

Perintah:
  node-add <name> <url> --wan-ip IP --ports MIN-MAX [--token T] [--desc D]
  node-list
  node-show <name> [--token]
  node-del <name>
  node-token <name> [--rotate]
  node-ping <name>
  alloc-list [node] [--free]
  server-list [--node N] [--json]
  server-show <name> [--json]
  setting-list | setting-set <key> <value>
  audit-tail [N]
  db-init
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import NoReturn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db  # noqa: E402


def out(msg: str = "") -> None:
    print(msg)


def fail(msg: str, code: int = 1) -> NoReturn:
    print(f"[x] {msg}", file=sys.stderr)
    raise SystemExit(code)


def norm_url(url: str) -> str:
    url = url.strip().rstrip("/")
    if not url.startswith(("http://", "https://")):
        url = "http://" + url
    host = url.split("://", 1)[1]
    if ":" not in host and not url.startswith("https://"):
        url = f"{url}:8788"
    return url


def parse_range(text: str) -> tuple[int, int]:
    cleaned = str(text).strip().replace(":", "-")
    if "-" in cleaned:
        a, b = cleaned.split("-", 1)
    else:
        a = b = cleaned
    if not (a.isdigit() and b.isdigit()):
        fail("rentang port harus MIN-MAX, contoh 20000-24999")
    lo, hi = int(a), int(b)
    if not (1 <= lo <= hi <= 65535):
        fail("rentang port tidak valid (1-65535, MIN <= MAX)")
    if lo < 1024:
        fail("rentang port harus >= 1024 (hindari port sistem)")
    return lo, hi


def cmd_node_add(a) -> None:
    lo, hi = parse_range(a.ports)
    if db.node_get(a.name):
        fail(f"node '{a.name}' sudah terdaftar")
    if not a.wan_ip or not all(p.isdigit() for p in a.wan_ip.split(".")):
        fail("--wan-ip wajib berupa IPv4 publik node (IP yang dipakai client untuk SSH)")
    node = db.node_add(
        name=a.name,
        url=norm_url(a.url),
        wan_ip=a.wan_ip,
        port_min=lo,
        port_max=hi,
        token=a.token or "",
        description=a.desc or "",
    )
    out(f"[+] Node '{node['name']}' ditambahkan.")
    out(f"    URL        : {node['url']}")
    out(f"    WAN IP     : {node['wan_ip']}")
    out(f"    Port pool  : {lo}-{hi} ({hi - lo + 1} port)")
    out(f"    Token      : {node['token']}")
    out("")
    out("Tempel perintah ini di NODE (butuh root):")
    out(f"  vpsnat node attach {node['token']}")


def cmd_node_list(a) -> None:
    nodes = db.nodes_all()
    if not nodes:
        out("(belum ada node terdaftar)")
        return
    stats = db.allocations_stats()
    counts = {}
    for s in db.servers_all():
        counts[s["node_id"]] = counts.get(s["node_id"], 0) + 1
    out(f"{'NAMA':<16} {'WAN IP':<16} {'PORT POOL':<16} {'SERVER':<7} {'PORT KOSONG':<12} STATUS")
    out("-" * 90)
    now = int(time.time())
    for n in nodes:
        st = stats.get(n["id"], {"total": 0, "free": 0})
        seen = f"{now - n['last_seen']}s" if n["last_seen"] else "belum"
        status = n["last_status"] if n["last_seen"] else "offline"
        out(
            f"{n['name']:<16} {n['wan_ip']:<16} {str(n['port_min']) + '-' + str(n['port_max']):<16} "
            f"{counts.get(n['id'], 0):<7} {str(st['free']) + '/' + str(st['total']):<12} {status} (sync {seen})"
        )


def cmd_node_show(a) -> None:
    node = db.node_get(a.name, with_token=True)
    if not node:
        fail("node tidak ditemukan")
    out(json.dumps(node, indent=2, ensure_ascii=False) if a.json else "\n".join(f"{k:<12}: {v}" for k, v in node.items()))
    if not a.token and not a.json:
        pass


def cmd_node_del(a) -> None:
    try:
        if not db.node_delete(a.name):
            fail("node tidak ditemukan")
    except ValueError as exc:
        fail(str(exc))
    out(f"[+] Node '{a.name}' dihapus (beserta alokasi port yang belum terpakai).")


def cmd_node_token(a) -> None:
    if a.rotate:
        out(db.node_rotate_token(a.name))
        return
    tok = db.node_token(a.name)
    if not tok:
        fail("node tidak ditemukan")
    out(tok)


def cmd_node_ping(a) -> None:
    node = db.node_get(a.name)
    if not node:
        fail("node tidak ditemukan")
    from nodeclient import NodeClient  # noqa: PLC0415

    client = NodeClient(node["url"], db.node_token(a.name) or "")
    try:
        info = client.system()
    except Exception as exc:  # noqa: BLE001
        fail(f"node tidak merespons: {exc}")
    out(f"[+] {node['name']} OK — {info.get('version', '?')} | {info.get('hostname', '?')}")
    out(f"    public_ip : {info.get('public_ip', '-')}")
    out(f"    vps       : {info.get('vps', {}).get('total', 0)} total")
    out(f"    lxd       : {info.get('lxd_version', '-')}")


def cmd_alloc_list(a) -> None:
    nodes = {n["id"]: n for n in db.nodes_all()}
    with db.read() as c:
        sql = "SELECT a.node_id, a.port, a.server_id, s.name AS server FROM allocations a LEFT JOIN servers s ON s.id=a.server_id"
        params: tuple = ()
        cond = []
        if a.node:
            node = db.node_get(a.node)
            if not node:
                fail("node tidak ditemukan")
            cond.append("a.node_id=?")
            params = (node["id"],)
        if a.free:
            cond.append("a.server_id IS NULL")
        if cond:
            sql += " WHERE " + " AND ".join(cond)
        sql += " ORDER BY a.node_id, a.port"
        rows = c.execute(sql, params).fetchall()
    for r in rows:
        name = nodes.get(r["node_id"], {}).get("name", str(r["node_id"]))
        out(f"{name:<16} {r['port']:<6} {r['server'] or '(kosong)'}")


def cmd_server_list(a) -> None:
    rows = db.servers_all(node_id=None)
    if a.node:
        node = db.node_get(a.node)
        if not node:
            fail("node tidak ditemukan")
        rows = [r for r in rows if r["node_id"] == node["id"]]
    if a.json:
        out(json.dumps(rows, indent=2, ensure_ascii=False))
        return
    if not rows:
        out("(belum ada server)")
        return
    nodes = {n["id"]: n for n in db.nodes_all()}
    out(f"{'NAMA':<16} {'NODE':<12} {'STATE':<10} {'SSH':<7} {'CPU':<4} {'RAM':<7} {'DISK':<6} OWNER")
    out("-" * 84)
    for r in rows:
        out(
            f"{r['name']:<16} {nodes.get(r['node_id'], {}).get('name', '?'):<12} "
            f"{('SUSPEND' if r['suspended'] else r['state']):<10} {r['ssh_port']:<7} {r['cpu']:<4} "
            f"{r['ram']:<7} {r['disk']:<6} {r['owner']}"
        )


def cmd_server_show(a) -> None:
    row = db.server_get(a.name)
    if not row:
        fail("server tidak ditemukan")
    if a.json:
        out(json.dumps(row, indent=2, ensure_ascii=False))
        return
    for k, v in row.items():
        out(f"{k:<12}: {v}")


def cmd_setting_list(a) -> None:
    for k, v in sorted(db.settings_all().items()):
        out(f"{k:<24} = {v}")


def cmd_setting_set(a) -> None:
    db.setting_set(a.key, a.value)
    out(f"[+] {a.key} = {a.value}")


def cmd_audit_tail(a) -> None:
    for row in db.audit_recent(a.count):
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(row["ts"]))
        out(f"{ts} {row['actor']:<14} {row['action']:<18} {row['target']:<16} {row['result']:<6} {row['detail']}")


def cmd_db_init(a) -> None:
    db.connect().close()
    out(f"[+] panel DB siap: {os.environ.get('VPSNAT_PANEL_DB', db.DEFAULT_DB)}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="panelctl", description="VPSNAT panel control-plane utility")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("node-add")
    s.add_argument("name")
    s.add_argument("url")
    s.add_argument("--wan-ip", required=True)
    s.add_argument("--ports", required=True)
    s.add_argument("--token", default="")
    s.add_argument("--desc", default="")
    s.set_defaults(func=cmd_node_add)

    s = sub.add_parser("node-list")
    s.set_defaults(func=cmd_node_list)

    s = sub.add_parser("node-show")
    s.add_argument("name")
    s.add_argument("--token", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_node_show)

    s = sub.add_parser("node-del")
    s.add_argument("name")
    s.set_defaults(func=cmd_node_del)

    s = sub.add_parser("node-token")
    s.add_argument("name")
    s.add_argument("--rotate", action="store_true")
    s.set_defaults(func=cmd_node_token)

    s = sub.add_parser("node-ping")
    s.add_argument("name")
    s.set_defaults(func=cmd_node_ping)

    s = sub.add_parser("alloc-list")
    s.add_argument("node", nargs="?")
    s.add_argument("--free", action="store_true")
    s.set_defaults(func=cmd_alloc_list)

    s = sub.add_parser("server-list")
    s.add_argument("--node")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_server_list)

    s = sub.add_parser("server-show")
    s.add_argument("name")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_server_show)

    s = sub.add_parser("setting-list")
    s.set_defaults(func=cmd_setting_list)

    s = sub.add_parser("setting-set")
    s.add_argument("key")
    s.add_argument("value")
    s.set_defaults(func=cmd_setting_set)

    s = sub.add_parser("audit-tail")
    s.add_argument("count", nargs="?", type=int, default=40)
    s.set_defaults(func=cmd_audit_tail)

    s = sub.add_parser("db-init")
    s.set_defaults(func=cmd_db_init)
    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
