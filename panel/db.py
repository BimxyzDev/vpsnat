#!/usr/bin/env python3
"""Lapisan data PANEL (control-plane) — SQLite stdlib.

Panel adalah sumber kebenaran untuk SEMUA data client: nama server, kredensial,
IP publik node, dan port SSH yang dipakai client untuk login. Node hanya
menjalankan proses (LXD) dan melaporkan keadaan sebenarnya.

Tabel:
  nodes        registry node + token agent + rentang port yang boleh dialokasikan
  allocations  port publik per node; dipakai ulang (tidak pernah dipakai dua client)
  servers      satu baris per VPS client (metadata + kredensial + alokasi)
  jobs         jejak operasi panjang (create/delete/reinstall) lintas restart
  settings     key/value panel (grace, interval sync, dsb.)
  audit        audit trail panel

Hanya memakai modul standar Python (sqlite3, json, secrets, time).
"""
from __future__ import annotations

import contextlib
import json
import os
import secrets
import sqlite3
import threading
import time

DEFAULT_DB = os.environ.get("VPSNAT_PANEL_DB", "/etc/vpsnat/panel.db")

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS nodes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL UNIQUE,
    url          TEXT NOT NULL,
    token        TEXT NOT NULL,
    wan_ip       TEXT NOT NULL DEFAULT '',
    port_min     INTEGER NOT NULL,
    port_max     INTEGER NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    maintenance  INTEGER NOT NULL DEFAULT 0,
    created      INTEGER NOT NULL,
    last_seen    INTEGER NOT NULL DEFAULT 0,
    last_status  TEXT NOT NULL DEFAULT 'unknown',
    last_error   TEXT NOT NULL DEFAULT '',
    system_json  TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS allocations (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id    INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    port       INTEGER NOT NULL,
    server_id  INTEGER,
    UNIQUE(node_id, port)
);
CREATE INDEX IF NOT EXISTS idx_alloc_node ON allocations(node_id);
CREATE INDEX IF NOT EXISTS idx_alloc_server ON allocations(server_id);

CREATE TABLE IF NOT EXISTS servers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL UNIQUE,
    node_id     INTEGER NOT NULL REFERENCES nodes(id) ON DELETE RESTRICT,
    owner       TEXT NOT NULL DEFAULT '-',
    plan        TEXT NOT NULL DEFAULT 'shared',
    backend     TEXT NOT NULL DEFAULT 'container',
    image       TEXT NOT NULL DEFAULT 'ubuntu22',
    cpu         INTEGER NOT NULL DEFAULT 1,
    ram         INTEGER NOT NULL DEFAULT 1024,
    disk        INTEGER NOT NULL DEFAULT 10,
    nesting     INTEGER NOT NULL DEFAULT 1,
    ssh_port    INTEGER NOT NULL,
    password    TEXT NOT NULL,
    created     TEXT NOT NULL DEFAULT '',
    expires     INTEGER NOT NULL DEFAULT 0,
    suspended   INTEGER NOT NULL DEFAULT 0,
    reason      TEXT NOT NULL DEFAULT '-',
    bw_quota    INTEGER NOT NULL DEFAULT 0,
    bw_rate     REAL NOT NULL DEFAULT 0,
    bw_rx       INTEGER NOT NULL DEFAULT 0,
    bw_tx       INTEGER NOT NULL DEFAULT 0,
    state       TEXT NOT NULL DEFAULT 'UNKNOWN',
    last_error  TEXT NOT NULL DEFAULT '',
    updated     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_srv_node ON servers(node_id);

CREATE TABLE IF NOT EXISTS jobs (
    id        TEXT PRIMARY KEY,
    kind      TEXT NOT NULL,
    target    TEXT NOT NULL DEFAULT '',
    node_id   INTEGER,
    node_job  TEXT NOT NULL DEFAULT '',
    status    TEXT NOT NULL DEFAULT 'running',
    rc        INTEGER,
    output    TEXT NOT NULL DEFAULT '',
    actor     TEXT NOT NULL DEFAULT '',
    started   INTEGER NOT NULL,
    finished  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_jobs_started ON jobs(started DESC);

CREATE TABLE IF NOT EXISTS settings (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     INTEGER NOT NULL,
    actor  TEXT NOT NULL DEFAULT '',
    action TEXT NOT NULL DEFAULT '',
    target TEXT NOT NULL DEFAULT '',
    result TEXT NOT NULL DEFAULT 'ok',
    detail TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit(ts DESC);
"""

DEFAULT_SETTINGS = {
    "brand": "VPSNAT",
    "node_sync_seconds": "15",
    "job_timeout": "1800",
    "grace_days": "3",
    "default_ports": "3",
    "ports_min": "2",
    "ports_max": "50",
    "default_quota_gb": "0",
    "default_rate_mbit": "0",
    "allow_user_reinstall": "0",
}

_local = threading.local()
_init_lock = threading.Lock()
_initialised: set[str] = set()


def _resolve(path: str | None = None) -> str:
    return path or os.environ.get("VPSNAT_PANEL_DB", DEFAULT_DB)


def connect(path: str | None = None) -> sqlite3.Connection:
    dbp = _resolve(path)
    directory = os.path.dirname(os.path.abspath(dbp))
    if directory:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    conn = sqlite3.connect(dbp, timeout=15, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=15000")
    with _init_lock:
        if dbp not in _initialised:
            conn.executescript(SCHEMA)
            for k, v in DEFAULT_SETTINGS.items():
                conn.execute("INSERT OR IGNORE INTO settings(k, v) VALUES(?, ?)", (k, v))
            with contextlib.suppress(OSError):
                os.chmod(dbp, 0o600)
            _initialised.add(dbp)
    return conn


@contextlib.contextmanager
def tx(path: str | None = None):
    """Transaksi tulis (BEGIN IMMEDIATE) — aman untuk beberapa worker thread."""
    conn = connect(path)
    try:
        conn.execute("BEGIN IMMEDIATE")
        yield conn
        conn.execute("COMMIT")
    except BaseException:
        with contextlib.suppress(sqlite3.Error):
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


@contextlib.contextmanager
def read(path: str | None = None):
    conn = connect(path)
    try:
        yield conn
    finally:
        conn.close()


# ---------------- settings ----------------
def settings_all(path: str | None = None) -> dict:
    with read(path) as c:
        return {r["k"]: r["v"] for r in c.execute("SELECT k, v FROM settings")}


def setting(key: str, default: str = "", path: str | None = None) -> str:
    with read(path) as c:
        row = c.execute("SELECT v FROM settings WHERE k=?", (key,)).fetchone()
    return row["v"] if row else default


def setting_set(key: str, value: str, path: str | None = None) -> None:
    with tx(path) as c:
        c.execute("INSERT INTO settings(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (key, str(value)))


def setting_int(key: str, default: int, path: str | None = None) -> int:
    raw = setting(key, "", path).strip()
    return int(raw) if raw.isdigit() else default


# ---------------- nodes ----------------
NODE_FIELDS = (
    "id", "name", "url", "wan_ip", "port_min", "port_max", "description",
    "maintenance", "created", "last_seen", "last_status", "last_error", "system_json",
)


def node_row(r) -> dict:
    d = {k: r[k] for k in NODE_FIELDS}
    try:
        d["system"] = json.loads(r["system_json"] or "{}")
    except (ValueError, TypeError):
        d["system"] = {}
    return d


def nodes_all(path: str | None = None) -> list[dict]:
    with read(path) as c:
        return [node_row(r) for r in c.execute("SELECT * FROM nodes ORDER BY name")]


def node_get(name_or_id, path: str | None = None, with_token: bool = False) -> dict | None:
    q = "SELECT * FROM nodes WHERE id=?" if isinstance(name_or_id, int) else "SELECT * FROM nodes WHERE name=?"
    with read(path) as c:
        r = c.execute(q, (name_or_id,)).fetchone()
    if not r:
        return None
    d = node_row(r)
    if with_token:
        d["token"] = r["token"]
    return d


def node_add(
    name: str,
    url: str,
    wan_ip: str,
    port_min: int,
    port_max: int,
    token: str = "",
    description: str = "",
    path: str | None = None,
) -> dict:
    token = token or secrets.token_hex(24)
    now = int(time.time())
    with tx(path) as c:
        cur = c.execute(
            "INSERT INTO nodes(name, url, token, wan_ip, port_min, port_max, description, created)"
            " VALUES(?,?,?,?,?,?,?,?)",
            (name, url, token, wan_ip, port_min, port_max, description, now),
        )
        node_id = cur.lastrowid
        c.executemany(
            "INSERT OR IGNORE INTO allocations(node_id, port) VALUES(?, ?)",
            [(node_id, p) for p in range(port_min, port_max + 1)],
        )
    return node_get(node_id, path, with_token=True) or {}


def node_delete(name: str, path: str | None = None) -> bool:
    with tx(path) as c:
        row = c.execute("SELECT id FROM nodes WHERE name=?", (name,)).fetchone()
        if not row:
            return False
        if c.execute("SELECT COUNT(*) AS n FROM servers WHERE node_id=?", (row["id"],)).fetchone()["n"]:
            raise ValueError("node masih memiliki server; hapus/pindahkan server terlebih dahulu")
        c.execute("DELETE FROM allocations WHERE node_id=?", (row["id"],))
        c.execute("DELETE FROM nodes WHERE id=?", (row["id"],))
    return True


def node_set(name: str, **fields) -> None:
    allowed = {"url", "wan_ip", "port_min", "port_max", "description", "maintenance", "token", "last_seen", "last_status", "last_error", "system_json"}
    sets = {k: v for k, v in fields.items() if k in allowed}
    if not sets:
        return
    cols = ", ".join(f"{k}=?" for k in sets)
    with tx() as c:
        c.execute(f"UPDATE nodes SET {cols} WHERE name=?", (*sets.values(), name))


def node_token(name: str, path: str | None = None) -> str | None:
    with read(path) as c:
        row = c.execute("SELECT token FROM nodes WHERE name=?", (name,)).fetchone()
    return row["token"] if row else None


def node_rotate_token(name: str, path: str | None = None) -> str:
    token = secrets.token_hex(24)
    with tx(path) as c:
        c.execute("UPDATE nodes SET token=? WHERE name=?", (token, name))
    return token


# ---------------- allocations ----------------
def allocations_free(node_id: int, limit: int = 50, path: str | None = None) -> list[int]:
    with read(path) as c:
        rows = c.execute(
            "SELECT port FROM allocations WHERE node_id=? AND server_id IS NULL ORDER BY port LIMIT ?",
            (node_id, limit),
        ).fetchall()
    return [r["port"] for r in rows]


def allocations_take(node_id: int, count: int, path: str | None = None) -> list[int]:
    """Ambil `count` port kosong milik node. Greedy: utamakan satu blok kontigu."""
    with tx(path) as c:
        rows = c.execute(
            "SELECT port FROM allocations WHERE node_id=? AND server_id IS NULL ORDER BY port",
            (node_id,),
        ).fetchall()
        free = [r["port"] for r in rows]
        if len(free) < count:
            raise ValueError(f"port kosong di node ini hanya {len(free)}, dibutuhkan {count}")
        best: list[int] = []
        run: list[int] = [free[0]]
        for p in free[1:]:
            if p == run[-1] + 1:
                run.append(p)
            else:
                if len(run) > len(best):
                    best = run
                run = [p]
        if len(run) > len(best):
            best = run
        picked = best[:count] if len(best) >= count else free[:count]
        return sorted(picked)


def allocations_assign(node_id: int, ports: list[int], server_id: int, path: str | None = None) -> None:
    with tx(path) as c:
        for p in ports:
            cur = c.execute(
                "UPDATE allocations SET server_id=? WHERE node_id=? AND port=? AND (server_id IS NULL OR server_id=?)",
                (server_id, node_id, p, server_id),
            )
            if cur.rowcount == 0:
                raise ValueError(f"port {p} tidak tersedia di node ini")


def allocations_release(server_id: int, path: str | None = None) -> None:
    with tx(path) as c:
        c.execute("UPDATE allocations SET server_id=NULL WHERE server_id=?", (server_id,))


def allocations_of(server_id: int, path: str | None = None) -> list[int]:
    with read(path) as c:
        return [r["port"] for r in c.execute("SELECT port FROM allocations WHERE server_id=? ORDER BY port", (server_id,))]


def allocations_stats(path: str | None = None) -> dict:
    with read(path) as c:
        rows = c.execute(
            "SELECT node_id, COUNT(*) AS total, SUM(CASE WHEN server_id IS NULL THEN 1 ELSE 0 END) AS free"
            " FROM allocations GROUP BY node_id"
        ).fetchall()
    return {r["node_id"]: {"total": r["total"], "free": r["free"] or 0} for r in rows}


# ---------------- servers ----------------
def server_row(r) -> dict:
    return {k: r[k] for k in r.keys()}


def servers_all(path: str | None = None, node_id: int | None = None) -> list[dict]:
    with read(path) as c:
        if node_id is None:
            rows = c.execute("SELECT * FROM servers ORDER BY name").fetchall()
        else:
            rows = c.execute("SELECT * FROM servers WHERE node_id=? ORDER BY name", (node_id,)).fetchall()
    return [server_row(r) for r in rows]


def server_get(name: str, path: str | None = None) -> dict | None:
    with read(path) as c:
        r = c.execute("SELECT * FROM servers WHERE name=?", (name,)).fetchone()
    return server_row(r) if r else None


def server_get_by_id(sid: int, path: str | None = None) -> dict | None:
    with read(path) as c:
        r = c.execute("SELECT * FROM servers WHERE id=?", (sid,)).fetchone()
    return server_row(r) if r else None


def server_by_ssh_port(port: int, path: str | None = None) -> dict | None:
    with read(path) as c:
        r = c.execute("SELECT * FROM servers WHERE ssh_port=?", (port,)).fetchone()
    return server_row(r) if r else None


def server_create(data: dict, path: str | None = None) -> dict:
    cols = (
        "uuid", "name", "node_id", "owner", "plan", "backend", "image", "cpu", "ram", "disk",
        "nesting", "ssh_port", "password", "created", "expires", "suspended", "reason",
        "bw_quota", "bw_rate", "state",
    )
    payload = {
        "uuid": data.get("uuid") or secrets.token_hex(8),
        "owner": data.get("owner") or "-",
        "plan": data.get("plan") or "shared",
        "backend": data.get("backend") or "container",
        "image": data.get("image") or "ubuntu22",
        "cpu": int(data.get("cpu") or 1),
        "ram": int(data.get("ram") or 1024),
        "disk": int(data.get("disk") or 10),
        "nesting": 1 if data.get("nesting", True) else 0,
        "created": data.get("created") or time.strftime("%Y-%m-%d"),
        "expires": int(data.get("expires") or 0),
        "suspended": int(bool(data.get("suspended"))),
        "reason": data.get("reason") or "-",
        "bw_quota": int(data.get("bw_quota") or 0),
        "bw_rate": float(data.get("bw_rate") or 0),
        "state": data.get("state") or "CREATING",
        "updated": int(time.time()),
        **{k: data[k] for k in ("name", "node_id", "ssh_port", "password") if k in data},
    }
    with tx(path) as c:
        cur = c.execute(
            f"INSERT INTO servers({', '.join(cols)}, updated) VALUES({', '.join('?' * len(cols))}, ?)",
            tuple(payload[k] for k in cols) + (int(time.time()),),
        )
        sid = cur.lastrowid
    return server_get_by_id(sid, path) or {}


def server_update(name: str, path: str | None = None, **fields) -> None:
    if not fields:
        return
    cols = ", ".join(f"{k}=?" for k in fields)
    with tx(path) as c:
        c.execute(f"UPDATE servers SET {cols}, updated=? WHERE name=?", (*fields.values(), int(time.time()), name))


def server_delete(name: str, path: str | None = None) -> dict | None:
    row = server_get(name, path)
    if not row:
        return None
    with tx(path) as c:
        c.execute("UPDATE allocations SET server_id=NULL WHERE server_id=?", (row["id"],))
        c.execute("DELETE FROM servers WHERE id=?", (row["id"],))
    return row


def servers_counts(path: str | None = None) -> dict:
    with read(path) as c:
        row = c.execute(
            "SELECT COUNT(*) AS total,"
            " SUM(CASE WHEN state='RUNNING' AND suspended=0 THEN 1 ELSE 0 END) AS running,"
            " SUM(CASE WHEN suspended=1 THEN 1 ELSE 0 END) AS suspended,"
            " COALESCE(SUM(cpu),0) AS cpu, COALESCE(SUM(ram),0) AS ram, COALESCE(SUM(disk),0) AS disk,"
            " COALESCE(SUM(bw_rx+bw_tx),0) AS bw FROM servers"
        ).fetchone()
    return {k: (row[k] or 0) for k in ("total", "running", "suspended", "cpu", "ram", "disk", "bw")}


# ---------------- jobs ----------------
def job_save(job: dict, path: str | None = None) -> None:
    with tx(path) as c:
        c.execute(
            "INSERT INTO jobs(id, kind, target, node_id, node_job, status, rc, output, actor, started, finished)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?)"
            " ON CONFLICT(id) DO UPDATE SET node_job=excluded.node_job, status=excluded.status,"
            " rc=excluded.rc, output=excluded.output, finished=excluded.finished",
            (
                job["id"], job["kind"], job.get("target", ""), job.get("node_id"),
                job.get("node_job", ""), job.get("status", "running"), job.get("rc"),
                (job.get("output") or "")[-8000:], job.get("actor", ""),
                job.get("started") or int(time.time()), job.get("finished"),
            ),
        )


def job_get(jid: str, path: str | None = None) -> dict | None:
    with read(path) as c:
        r = c.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
    return dict(r) if r else None


def jobs_recent(limit: int = 30, path: str | None = None) -> list[dict]:
    with read(path) as c:
        rows = c.execute("SELECT * FROM jobs ORDER BY started DESC LIMIT ?", (limit,)).fetchall()
    return [dict(r) for r in rows]


def jobs_prune(keep: int = 300, path: str | None = None) -> None:
    with tx(path) as c:
        c.execute(
            "DELETE FROM jobs WHERE id NOT IN (SELECT id FROM jobs ORDER BY started DESC LIMIT ?)",
            (keep,),
        )


def jobs_interrupt_running(path: str | None = None) -> int:
    """Tandai job yang masih 'running' sebagai interrupted (panel baru restart)."""
    with tx(path) as c:
        cur = c.execute(
            "UPDATE jobs SET status='interrupted', rc=124, finished=?,"
            " output=output || char(10) || '[!] Panel restart saat operasi berlangsung; periksa node.'"
            " WHERE status='running'",
            (int(time.time()),),
        )
    return cur.rowcount


# ---------------- audit ----------------
def audit_add(actor: str, action: str, target: str = "", result: str = "ok", detail: str = "", path: str | None = None) -> None:
    with contextlib.suppress(sqlite3.Error):
        with tx(path) as c:
            c.execute(
                "INSERT INTO audit(ts, actor, action, target, result, detail) VALUES(?,?,?,?,?,?)",
                (int(time.time()), str(actor)[:120], str(action)[:60], str(target)[:120], str(result)[:20], str(detail)[:400]),
            )


def audit_recent(limit: int = 100, path: str | None = None) -> list[dict]:
    with read(path) as c:
        rows = c.execute("SELECT * FROM audit ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()
    return [dict(r) for r in rows]
