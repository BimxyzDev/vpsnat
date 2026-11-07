#!/usr/bin/env python3
"""Registry job panel — satu baris `jobs` per operasi panjang.

Alur job (create/delete/reinstall):

    request HTTP  →  jobs.spawn()      menulis baris jobs (status=running)
                     jobs.dispatch()   worker mengirim ke node, menerima node_job
                     jobs.poll()       worker memantau sampai node selesai
                     jobs.finish()     hasil ditulis ke panel DB

Request HTTP tidak pernah menunggu provisioning: ia hanya membuat baris job dan
membalas 202 dengan id job. Worker (panel/worker.py + systemd timer) yang
mengerjakannya. Karena status ada di DB, restart panel tidak menghilangkan job:
job yang masih 'running' tanpa node_job dicoba lagi, sedangkan job yang sudah
dikirim tetap bisa dipoll ulang.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import secrets
import sys
import threading
import time

import db
from nodeclient import NodeClient, NodeError

MAX_ACTIVE = 64
JOB_ID_RE = re.compile(r"^[0-9a-f]{12}$")
_local = threading.local()
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _lock(key: str) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(key, threading.Lock())


@contextlib.contextmanager
def held(*keys):
    acquired = []
    try:
        for k in sorted(set(keys)):
            lk = _lock(k)
            lk.acquire()
            acquired.append(lk)
        yield
    finally:
        for lk in reversed(acquired):
            lk.release()


def client_for(node_id: int, timeout: float = 45.0) -> NodeClient:
    node = db.node_get(int(node_id), with_token=True)
    if not node:
        raise NodeError(f"node id {node_id} tidak ada di panel")
    return NodeClient(str(node.get("url") or ""), str(node.get("token") or ""), timeout=timeout)


def busy(name: str) -> str | None:
    """True bila ada job berjalan untuk server ini."""
    with db.read() as c:
        row = c.execute(
            "SELECT id FROM jobs WHERE target=? AND status='running' LIMIT 1", (name,)
        ).fetchone()
    return row["id"] if row else None


def ensure_idle(name: str) -> None:
    jid = busy(name)
    if jid:
        raise BusyError(f"Server sedang diproses (job {jid}). Tunggu sampai selesai.")


class BusyError(Exception):
    pass


def spawn(kind: str, target: str, node_id: int, actor: str, payload: dict | None = None) -> dict:
    """Buat baris job baru; worker akan mengirimnya ke node."""
    with _lock("__jobs__"):
        active = 0
        with db.read() as c:
            active = c.execute("SELECT COUNT(*) AS n FROM jobs WHERE status='running'").fetchone()["n"]
            dup = c.execute(
                "SELECT id FROM jobs WHERE target=? AND status='running' LIMIT 1", (target,)
            ).fetchone()
        if dup:
            raise BusyError(f"Server sedang diproses (job {dup['id']}). Tunggu sampai selesai.")
        if active >= MAX_ACTIVE:
            raise BusyError("Panel sibuk: batas 64 job aktif. Coba lagi nanti.")
        job = {
            "id": secrets.token_hex(6),
            "kind": kind,
            "target": target,
            "node_id": int(node_id),
            "node_job": "",
            "status": "running",
            "rc": None,
            "output": json.dumps(payload or {}, separators=(",", ":")),
            "actor": actor,
            "started": int(time.time()),
            "finished": None,
        }
        db.job_save(job)
        return job


def view(job: dict) -> dict:
    return {
        "id": job["id"],
        "kind": job["kind"],
        "name": job.get("target", ""),
        "status": job["status"],
        "rc": job["rc"],
        "output": job.get("output") or "",
        "started": job["started"],
        "finished": job["finished"],
    }


def interrupt_running() -> int:
    """Panel baru start: job 'running' yang belum dikirim ditandai interrupted."""
    now = int(time.time())
    with db.read() as c:
        rows = [dict(r) for r in c.execute("SELECT * FROM jobs WHERE status='running'")]
    n = 0
    for job in rows:
        if job.get("node_job"):
            continue  # sudah dikirim ke node; reconciliation akan menyelesaikannya
        db.job_save({
            **job, "status": "interrupted", "rc": 124, "finished": now,
            "output": "[!] Panel restart sebelum job dikirim ke node; jalankan ulang operasinya.",
        })
        n += 1
    return n


def _mark(job: dict, status: str, rc, output: str, node_job: str | None = None) -> None:
    db.job_save({
        **job,
        "node_job": job.get("node_job", "") if node_job is None else node_job,
        "status": status,
        "rc": rc,
        "output": (output or "")[-8000:],
        "finished": int(time.time()) if status != "running" else None,
    })


def dispatch(job: dict, max_wait: int = 1800) -> None:
    """Kirim satu job ke node dan tunggu sampai selesai (dipakai worker)."""
    node_job = job.get("node_job") or ""
    try:
        client = client_for(int(job["node_id"]))
    except (NodeError, TypeError, ValueError) as exc:
        _mark(job, "error", 1, f"[x] {exc}")
        return

    if not node_job:
        try:
            payload = json.loads(job.get("output") or "{}")
        except ValueError:
            payload = {}
        try:
            if job["kind"] == "create":
                node_job = client.create(payload)
            elif job["kind"] == "delete":
                node_job = client.delete(job["target"])
            elif job["kind"] == "reinstall":
                node_job = client.reinstall(job["target"], payload.get("image", "ubuntu22"))
            else:
                raise NodeError(f"jenis job tidak dikenal: {job['kind']}")
        except (NodeError, ValueError) as exc:
            _mark(job, "error", 1, f"[x] {exc}")
            return
        db.job_save({**job, "node_job": node_job, "output": ""})
        job = {**job, "node_job": node_job, "output": ""}

    deadline = time.time() + max_wait
    while time.time() < deadline:
        try:
            remote = client.job(node_job)
        except NodeError as exc:
            _mark(job, "error", 1, f"[x] {exc}", node_job=node_job)
            return
        status = str(remote.get("status") or "error")
        if status != "running":
            _mark(job, "done" if status == "done" else status,
                  remote.get("rc"), remote.get("output") or "", node_job=node_job)
            return
        time.sleep(2)
    _mark(job, "error", 124, "[x] job node melewati batas waktu pemantauan", node_job=node_job)


def reconcile() -> int:
    """Perbarui job 'running' yang sudah punya node_job dengan status terakhir dari node."""
    with db.read() as c:
        rows = [dict(r) for r in c.execute("SELECT * FROM jobs WHERE status='running' AND node_job<>''")]
    done = 0
    for job in rows:
        try:
            remote = client_for(int(job["node_id"])).job(job["node_job"])
        except (NodeError, TypeError, ValueError):
            continue
        status = str(remote.get("status") or "running")
        if status != "running":
            _mark(job, "done" if status == "done" else status,
                  remote.get("rc"), remote.get("output") or "")
            done += 1
    return done


def sync_output(name: str) -> str:
    """Ambil output job terakhir untuk server ini (dipakai UI setelah job selesai)."""
    with db.read() as c:
        row = c.execute(
            "SELECT output FROM jobs WHERE target=? ORDER BY started DESC LIMIT 1", (name,)
        ).fetchone()
    return (row["output"] if row else "") or ""


def node_job_stream(node_id: int, node_job: str) -> str:
    """Ambil output job langsung dari node (mis. saat panel kehilangan jejak)."""
    try:
        return str(client_for(int(node_id)).job(node_job).get("output") or "")
    except (NodeError, TypeError, ValueError):
        return ""


if __name__ == "__main__":  # pragma: no cover - utilitas cepat
    db.connect().close()
    print(json.dumps({"interrupted": interrupt_running()}, indent=2))
    sys.exit(0)
