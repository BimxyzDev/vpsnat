#!/usr/bin/env python3
"""Tes integrasi panel ↔ node (mock) — end-to-end tanpa LXD.

Menjalankan:
  1. agent node tiruan (tests/mock_node.py) di port lokal
  2. panel web sungguhan (panel/app.py) di port lokal
lalu memverifikasi alur lengkap: login admin, daftar node, alokasi port,
buat server (job), sync, login client, ganti password, dan hapus server.

    python3 tests/test_panel.py
"""
from __future__ import annotations

import http.cookiejar
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANEL = os.path.join(ROOT, "panel")
FAILED: list[str] = []
PASSED = 0


def check(name: str, cond: bool, extra: str = "") -> None:
    global PASSED
    if cond:
        PASSED += 1
        print(f"  ok   {name}")
    else:
        FAILED.append(name)
        print(f"  FAIL {name} {extra}")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Client:
    """Klien HTTP dengan cookie jar (meniru browser pada panel)."""

    def __init__(self, base: str):
        self.base = base
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method: str, path: str, body=None, headers=None):
        data = None
        h = {"Content-Type": "application/json", "X-Requested-With": "vpsnat"}
        if body is not None:
            data = json.dumps(body).encode()
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=data, headers=h, method=method)
        try:
            with self.opener.open(req, timeout=20) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw or b"{}")
            except ValueError:
                return e.code, {"raw": raw.decode("utf-8", "replace")}

    def get(self, path):
        return self.call("GET", path)

    def raw_get(self, path):
        """GET yang mengembalikan teks mentah (untuk HTML/CSS/JS)."""
        req = urllib.request.Request(self.base + path, headers={"X-Requested-With": "vpsnat"})
        with self.opener.open(req, timeout=15) as r:
            return r.status, r.read().decode("utf-8", "replace"), dict(r.headers)

    def post(self, path, body=None):
        return self.call("POST", path, body if body is not None else {})

    def delete(self, path):
        return self.call("DELETE", path)


def wait_port(port: int, timeout: float = 15.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        with socket.socket() as s:
            s.settimeout(0.4)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.15)
    return False


WORKER_LOOP = """
import os, sys, time
sys.path.insert(0, os.environ["VPSNAT_PANEL_DIR"])
import db, jobs, sync, worker
while True:
    try:
        worker.main()
    except Exception as exc:
        print("worker error:", repr(exc), file=sys.stderr, flush=True)
    time.sleep(0.4)
"""


def make_conf(path: str, admin_hash: str, api_key: str, web_port: int) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            f"WEB_PORT={web_port}\nWEB_BIND=127.0.0.1\nWEB_ADMIN_USER=admin\n"
            f"WEB_ADMIN_HASH={admin_hash}\nWEB_API_KEY={api_key}\nWEB_SESSION_HOURS=1\nWEB_BRAND=Uji Panel\n"
        )
    os.chmod(path, 0o600)


def main() -> int:
    work = tempfile.mkdtemp(prefix="vpsnat-test-")
    node_port, panel_port = free_port(), free_port()
    node_token = "deadbeef" * 4
    panel_db = os.path.join(work, "panel.db")
    conf_file = os.path.join(work, "vpsnat.conf")
    mock_state = os.path.join(work, "mock.json")
    api_key = "k" * 40

    env = dict(os.environ)
    env["PYTHONPATH"] = PANEL
    env["VPSNAT_PANEL_DB"] = panel_db

    # hash password admin lewat panel/app.py (perilaku produksi)
    admin_pw = "PasswordAdmin123"
    proc = subprocess.run([sys.executable, os.path.join(PANEL, "app.py"), "hashpw"],
                          input=admin_pw.encode(), capture_output=True, env=env, check=True)
    admin_hash = proc.stdout.decode().strip()
    check("hashpw menghasilkan scrypt", admin_hash.startswith("scrypt:"), admin_hash[:20])
    make_conf(conf_file, admin_hash, api_key, panel_port)
    env["VPSNAT_WEB_CONF"] = conf_file
    env["VPSNAT_PANEL_DIR"] = PANEL

    node = subprocess.Popen([sys.executable, os.path.join(ROOT, "tests", "mock_node.py"),
                             "--port", str(node_port), "--token", node_token, "--state", mock_state],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    panel = subprocess.Popen([sys.executable, os.path.join(PANEL, "app.py")],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, start_new_session=True)
    # Worker job: di produksi dijalankan systemd timer tiap 20 detik; di tes ini
    # berjalan sebagai loop cepat supaya job selesai dalam hitungan detik.
    worker = subprocess.Popen([sys.executable, "-c", WORKER_LOOP],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              env=env, start_new_session=True)
    try:
        if not wait_port(node_port) or not wait_port(panel_port, 20):
            err = panel.stderr.read(2000).decode(errors="replace") if panel.stderr else ""
            print("gagal menyalakan panel:\n" + err[-2000:])
            return 1

        base = f"http://127.0.0.1:{panel_port}"
        c = Client(base)

        print("\n[1] sesi & login")
        st, d = c.get("/api/session")
        check("GET /api/session ok", st == 200 and d.get("ok") and d.get("role") is None, str(d))
        check("branding dari DB dipakai", d.get("brand") == "Uji Panel", str(d.get("brand")))
        st, d = c.post("/api/login/admin", {"username": "admin", "password": "salah"})
        check("login salah ditolak 401", st == 401, str(d))
        st, d = c.post("/api/login/admin", {"username": "admin", "password": admin_pw})
        check("login admin berhasil", st == 200 and d.get("role") == "admin", str(d))
        st, d = c.get("/api/session")
        check("sesi admin terbaca", d.get("role") == "admin", str(d))

        print("\n[2] daftar node + pool port")
        st, d = c.post("/api/admin/nodes", {"name": "node-1", "wan_ip": "203.0.113.10",
                                            "url": f"http://127.0.0.1:{node_port}", "token": node_token,
                                            "port_min": 20000, "port_max": 20009})
        check("POST /api/admin/nodes 201", st == 201 and d.get("node", {}).get("name") == "node-1", str(d)[:200])
        check("token node dikembalikan", d.get("token") == node_token, str(d.get("token"))[:20])
        st, d = c.post("/api/admin/nodes", {"name": "node-1", "wan_ip": "203.0.113.10"})
        check("node duplikat ditolak 409", st == 409, str(d))
        st, d = c.get("/api/admin/allocations")
        ports = sorted(a["port"] for a in d.get("allocations", []))
        check("pool port terbuat 10 alokasi", ports == list(range(20000, 20010)), str(ports))
        st, d = c.post("/api/admin/nodes/node-1/ping", {})
        check("ping node online", d.get("online") is True, str(d)[:200])
        st, d = c.get("/api/admin/dashboard")
        check("dashboard: 1 node online", d["summary"]["nodes_online"] == 1, str(d["summary"]))

        print("\n[3] buat server (job + alokasi port)")
        st, d = c.post("/api/admin/servers", {"name": "web-01", "node_id": 1, "cpu": 2, "ram": 2048,
                                             "disk": 20, "ports": 4, "expire": "30d", "owner": "budi"})
        check("POST /api/admin/servers 202", st == 202 and len(str(d.get("job", ""))) == 12, str(d)[:200])
        job = d["job"]
        srv = d["server"]
        check("port SSH dialokasikan dari pool node", srv["ssh"] in range(20000, 20010), str(srv["ssh"]))
        check("4 port dialokasikan", len(srv["ports"]) == 4, str(srv["ports"]))
        check("password acak dibuat", len(srv["password"]) >= 8, str(srv["password"])[:6])
        st, d2 = c.get("/api/admin/allocations")
        used = [a for a in d2["allocations"] if a["server"] == "web-01"]
        check("alokasi tercatat milik web-01", len(used) == 4, str(used))

        deadline = time.time() + 40
        status = "running"
        while time.time() < deadline and status == "running":
            time.sleep(0.6)
            st, j = c.get(f"/api/jobs/{job}")
            status = j.get("job", {}).get("status", "error")
        check(f"job create selesai ({status})", status == "done", str(j)[:300])

        print("\n[4] state, resource, dan sync")
        st, d = c.get("/api/admin/servers/web-01")
        v = d["server"]
        check("server RUNNING setelah job", v["state"] == "RUNNING", str(v["state"]))
        check("host = WAN IP node", v["host"] == "203.0.113.10", str(v["host"]))
        st, d = c.get("/api/admin/servers/web-01/resources")
        check("resource live dari node", d["res"]["cpu"]["cores"] == 2, str(d)[:200])
        st, d = c.post("/api/sync", {})
        check("POST /api/sync ok", st == 200 and d.get("nodes_online") == 1, str(d)[:200])

        print("\n[5] operasi server")
        st, d = c.post("/api/admin/servers/web-01/power", {"action": "stop"})
        check("power stop ok", st == 200, str(d)[:150])
        st, d = c.get("/api/admin/servers/web-01")
        check("state STOPPED tercermin di panel", d["server"]["state"] == "STOPPED", str(d["server"]["state"]))
        st, d = c.post("/api/admin/servers/web-01/power", {"action": "start"})
        st, d = c.post("/api/admin/servers/web-01/resize", {"cpu": 4, "ram": 4096})
        check("resize ok", st == 200, str(d)[:150])
        st, d = c.get("/api/admin/servers/web-01")
        check("resize tercatat di panel", d["server"]["cpu"] == 4 and d["server"]["ram"] == 4096, str(d["server"]["cpu"]))
        st, d = c.post("/api/admin/servers/web-01/ports", {"proto": "tcp", "count": 2})
        check("tambah 2 port dari pool", st == 200 and len(d.get("ports", [])) == 2, str(d)[:150])
        st, d = c.get("/api/admin/servers/web-01")
        check("server punya 6 port", len(d["server"]["ports"]) == 6, str(len(d["server"]["ports"])))
        st, d = c.post("/api/admin/servers/web-01/password", {"password": "PasswordBaru123"})
        check("ganti password ok", st == 200 and d.get("password") == "PasswordBaru123", str(d)[:150])
        st, d = c.post("/api/admin/servers/web-01/expire", {"value": "30d", "relative": True})
        check("renew ok", st == 200 and d.get("expires", 0) > time.time(), str(d)[:150])
        st, d = c.post("/api/admin/servers/web-01/owner", {"owner": "budi-2"})
        check("ubah owner ok", st == 200, str(d)[:150])

        print("\n[6] login client (port SSH + password root)")
        cu = Client(base)
        st, d = cu.post("/api/login/user", {"identifier": "web-01", "password": "PasswordBaru123"})
        check("login client via nama", st == 200 and d.get("role") == "user", str(d))
        cu2 = Client(base)
        st, d = cu2.post("/api/login/user", {"identifier": str(d2 and v["ssh"]), "password": "PasswordBaru123"})
        check("login client via port SSH", st == 200 and d.get("name") == "web-01", str(d))
        st, d = cu.get("/api/me")
        check("client melihat servernya", st == 200 and d["server"]["name"] == "web-01", str(d)[:150])
        st, d = cu.get("/api/me/resources")
        check("client melihat resource", st == 200 and d["res"]["state"] in ("RUNNING", "STOPPED"), str(d)[:150])
        st, d = cu.post("/api/me/action", {"action": "start"})
        check("client bisa start", st == 200, str(d)[:150])
        st, d = cu.post("/api/me/reinstall", {})
        check("reinstall oleh client ditolak 403", st == 403, str(d))
        st, d = cu.get("/api/admin/servers")
        check("client tidak bisa lihat daftar admin (403)", st in (403, 401), str(st))

        print("\n[7] keamanan")
        st, d = c.post("/api/admin/servers", {"name": "web-01"})
        check("nama duplikat ditolak 409", st == 409, str(d))
        st, d = c.post("/api/admin/servers", {"name": "BAD NAME"})
        check("nama tidak valid ditolak 422", st == 422, str(d))
        st, d = c.post("/api/admin/nodes", {"name": "n2", "wan_ip": "bukan-ip"})
        check("WAN IP tidak valid ditolak 422", st == 422, str(d))
        st, d = c.call("POST", "/api/admin/servers", {"name": "x"}, headers={"X-Requested-With": ""})
        check("tanpa X-Requested-With ditolak 403", st == 403, str(d))
        raw = Client(base)
        st, d = raw.call("GET", "/api/admin/jobs", headers={"Authorization": f"Bearer {api_key}"})
        check("API key admin diterima", st == 200 and d.get("ok"), str(d)[:120])
        st, d = raw.call("GET", "/api/admin/jobs", headers={"Authorization": "Bearer " + "x" * 40})
        check("API key salah ditolak 401", st == 401, str(d))
        st, d = c.call("POST", "/api/login/admin", {"username": "admin", "password": "p"},
                       headers={"Authorization": "Bearer " + "x" * 40})
        check("kombinasi key salah + login tidak 500", st in (401, 429), str(st))

        print("\n[8] halaman UI terpisah")
        for path, needle in (("/", "page-dashboard.js"), ("/servers", "page-servers.js"),
                             ("/servers/web-01", "page-server.js"), ("/nodes", "page-nodes.js"),
                             ("/jobs", "page-jobs.js"), ("/settings", "page-settings.js"),
                             ("/api-docs", "page-api.js"), ("/login", "page-login.js"),
                             ("/account", "page-account.js")):
            status, html, _h = c.raw_get(path)
            check(f"halaman {path} menyajikan UI-nya sendiri", status == 200 and needle in html,
                  f"{status} {needle}")
        status, css, _h = c.raw_get("/static/css/app.css")
        check("CSS statis tersedia", status == 200 and "--ac:#2563eb" in css, str(status))
        status, js, _h = c.raw_get("/static/js/app.js")
        check("app.js tersedia", status == 200 and "window.vpsnat" in js, str(status))
        st, oa = c.get("/api/openapi")
        check("openapi mendokumentasikan >= 40 endpoint", st == 200 and len(oa["endpoints"]) >= 40, str(len(oa.get("endpoints", []))))
        undocumented = [e["path"] for e in oa["endpoints"] if e["undocumented"]]
        check("hampir semua endpoint punya deskripsi", len(undocumented) <= 6, str(undocumented[:6]))

        print("\n[9] hapus server melepas alokasi port")
        st, d = c.delete("/api/admin/servers/web-01")
        check("DELETE 202 + job", st == 202 and len(str(d.get("job", ""))) == 12, str(d)[:150])
        deadline = time.time() + 20
        status = "running"
        while time.time() < deadline and status == "running":
            time.sleep(0.6)
            st, j = c.get(f"/api/jobs/{d['job']}")
            status = j.get("job", {}).get("status", "error")
        check(f"job delete selesai ({status})", status == "done", str(j)[:200])
        st, d = c.get("/api/admin/servers")
        check("server terhapus dari panel", all(s["name"] != "web-01" for s in d["servers"]), str(d)[:120])
        st, d = c.get("/api/admin/allocations")
        still = [a for a in d["allocations"] if a["server"] == "web-01"]
        check("port web-01 dilepas kembali ke pool", len(still) == 0, f"{len(still)} masih terikat")

        print("\n[10] worker menyelesaikan sisa pekerjaan")
        env2 = dict(env)
        env2["VPSNAT_PANEL_DB"] = panel_db
        r = subprocess.run([sys.executable, os.path.join(PANEL, "worker.py")], capture_output=True, env=env2, timeout=60)
        check("worker.py berjalan tanpa error", r.returncode == 0, r.stderr.decode()[-300:])

    finally:
        for p in (panel, node, worker):
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        time.sleep(0.4)

    print(f"\n=== {PASSED} lulus, {len(FAILED)} gagal ===")
    if FAILED:
        print("gagal: " + ", ".join(FAILED))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
