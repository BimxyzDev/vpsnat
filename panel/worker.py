#!/usr/bin/env python3
"""Panel job worker — inti dari control-plane.

Dijalankan berkala (systemd timer `vpsnat-panel-worker.timer`, tiap 20 detik):

  1. Menjalankan job yang masih 'running' dan belum punya node_job: dikirim ke
     agent node, lalu statusnya dipantau sampai selesai.
  2. Merekonsiliasi job 'running' yang sudah dikirim (mis. panel restart saat job
     berjalan) dengan status terakhir di node.
  3. Menyinkronkan state/kredensial/pemakaian bandwidth setiap server dari node.

Karena status job hidup di panel DB, job tidak hilang saat panel restart: operasi
yang belum sempat dikirim ditandai interrupted oleh jobs.interrupt_running(),
sedangkan yang sudah dikirim tetap dilacak di sini.

Request HTTP tidak pernah memblokir: ia hanya membuat baris job lalu membalas 202.
"""
from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
import jobs  # noqa: E402
import sync as syncmod  # noqa: E402

LOG = os.environ.get("VPSNAT_PANEL_WORKER_LOG", "/etc/vpsnat/panel-worker.log")


def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        directory = os.path.dirname(LOG)
        if directory:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def pending() -> list[dict]:
    with db.read() as c:
        rows = c.execute(
            "SELECT * FROM jobs WHERE status='running' AND (node_job IS NULL OR node_job='')"
            " ORDER BY started ASC LIMIT 8"
        ).fetchall()
    return [dict(r) for r in rows]


def main() -> int:
    db.connect().close()
    handled = 0
    for job in pending():
        try:
            log(f"job {job['id']} {job['kind']} {job['target']} -> node {job['node_id']}")
            jobs.dispatch(job)
            after = db.job_get(job["id"]) or {}
            log(f"job {job['id']} selesai: {after.get('status')} (rc={after.get('rc')})")
            handled += 1
            if job["kind"] == "delete":
                syncmod.forget_server(job["target"])
            else:
                syncmod.sync_server(job["target"], quiet=True)
        except Exception as exc:  # noqa: BLE001
            log(f"job {job['id']} gagal: {exc!r}")
            db.job_save({**job, "status": "error", "rc": 1,
                         "output": f"[x] worker: {exc}", "finished": int(time.time())})

    try:
        reconciled = jobs.reconcile()
    except Exception as exc:  # noqa: BLE001
        reconciled = 0
        log(f"reconcile gagal: {exc!r}")

    try:
        changed = syncmod.sync_all(quiet=True)
    except Exception as exc:  # noqa: BLE001
        changed = 0
        log(f"sync gagal: {exc!r}")

    try:
        syncmod.node_health()
    except Exception as exc:  # noqa: BLE001
        log(f"health node gagal: {exc!r}")

    if handled or reconciled or changed:
        log(f"ringkasan: {handled} job dijalankan, {reconciled} direkonsiliasi, {changed} server diperbarui")
    db.jobs_prune(300)
    return 0


if __name__ == "__main__":
    sys.exit(main())
