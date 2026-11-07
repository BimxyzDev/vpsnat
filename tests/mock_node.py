#!/usr/bin/env python3
"""Mock agent NODE untuk tes panel (stdlib saja).

Meniru kontrak `node/agent.py` tanpa LXD, supaya seluruh alur control-plane
(pendaftaran node, alokasi port, job, sync, login client) bisa diuji nyata.

    python3 tests/mock_node.py --port 8788 --token <token> [--state /tmp/mock.json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

VERSION = "4.0.0-mock"
PREFIX = "/api/v1"

LOCK = threading.Lock()
STATE: dict = {"instances": {}, "jobs": {}}


def load(path: str) -> None:
    global STATE
    try:
        with open(path, encoding="utf-8") as f:
            STATE = json.load(f)
    except (OSError, ValueError):
        STATE = {"instances": {}, "jobs": {}}


def save(path: str) -> None:
    with LOCK:
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(STATE, f)
        os.replace(tmp, path)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = ""
    statefile = "/tmp/vpsnat-mock-state.json"

    def log_message(self, format, *args):  # noqa: A002
        pass

    def _json(self, code: int, obj: dict) -> None:
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth(self) -> bool:
        return self.headers.get("Authorization") == f"Bearer {self.token}"

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):  # noqa: N802
        self.dispatch("GET")

    def do_POST(self):  # noqa: N802
        self.dispatch("POST")

    def do_DELETE(self):  # noqa: N802
        self.dispatch("DELETE")

    def dispatch(self, method):
        path = urlparse(self.path).path
        if not path.startswith(PREFIX):
            return self._json(404, {"ok": False, "error": "not found"})
        if not self._auth():
            return self._json(401, {"ok": False, "error": "token salah"})
        sub = path[len(PREFIX):]
        parts = [p for p in sub.split("/") if p]
        body = self._body() if method in ("POST", "DELETE") else {}

        if parts == ["system"]:
            return self._json(200, {"ok": True, "system": {
                "version": VERSION, "hostname": "mock-node", "public_ip": "203.0.113.10",
                "cores": 4, "load": [0.1, 0.2, 0.2], "ram": {"total": 8589934592, "avail": 6442450944},
                "disk": {"total": 107374182400, "used": 21474836480}, "uptime": 123456,
                "lxd_version": "5.21", "vps": {"total": len(STATE["instances"]), "running": len(STATE["instances"]), "suspended": 0},
            }})

        if parts == ["instances"]:
            if method == "GET":
                return self._json(200, {"ok": True, "instances": [
                    {"name": n, **{k: v for k, v in i.items() if k != "password"}} for n, i in STATE["instances"].items()]})
            if method == "POST":
                name = body.get("name")
                if name in STATE["instances"]:
                    return self._json(409, {"ok": False, "error": "sudah ada"})
                job = secrets.token_hex(6)
                STATE["instances"][name] = {
                    "name": name, "state": "RUNNING", "suspended": False, "reason": "-",
                    "plan": body.get("plan", "shared"), "backend": body.get("backend", "container"),
                    "cpu": body.get("cpu", 1), "ram": body.get("ram", 1024), "disk": body.get("disk", 10),
                    "created": time.strftime("%Y-%m-%d"), "expires": 0, "ssh": body.get("ssh_port", 0),
                    "ip": "10.10.10.2", "owner": body.get("owner", "-"),
                    "password": body.get("password") or secrets.token_urlsafe(9),
                    "ports": [{"public": p, "internal": 22 if p == body.get("ssh_port") else p,
                               "proto": "tcp" if p == body.get("ssh_port") else "tcp+udp",
                               "ssh": p == body.get("ssh_port")} for p in (body.get("ports") or [])],
                    "bw": {"used": 0, "rx": 0, "tx": 0, "quota": 0, "rate": 0, "exhausted": False},
                }
                STATE["jobs"][job] = {"id": job, "kind": "create", "name": name, "status": "running",
                                      "rc": None, "output": "mock create\n", "started": int(time.time()), "finished": None}
                save(self.statefile)
                threading.Timer(0.4, self._finish, args=(job, 0)).start()
                return self._json(202, {"ok": True, "job": job})

        if len(parts) >= 2 and parts[0] == "instances":
            name = parts[1]
            inst = STATE["instances"].get(name)
            if inst is None:
                return self._json(404, {"ok": False, "error": "instance tidak ada"})
            rest = parts[2:]
            if not rest and method == "GET":
                return self._json(200, {"ok": True, "instance": inst})
            if not rest and method == "DELETE":
                job = secrets.token_hex(6)
                STATE["jobs"][job] = {"id": job, "kind": "delete", "name": name, "status": "running", "rc": None,
                                      "output": "mock delete\n", "started": int(time.time()), "finished": None}
                save(self.statefile)
                threading.Timer(0.4, self._finish_delete, args=(job, name)).start()
                return self._json(202, {"ok": True, "job": job})
            if rest == ["resources"] and method == "GET":
                return self._json(200, {"ok": True, "res": {
                    "state": inst["state"], "cpu": {"pct": 3.3, "cores": inst["cpu"]},
                    "ram": {"used": 310000000, "limit": inst["ram"] * 1000000, "pct": 15.1},
                    "disk": {"used": 2000000000, "limit": inst["disk"] * 1000000000, "pct": 10},
                    "net": {"rx": 1024, "tx": 2048}, "procs": 42, "bw": inst["bw"]}})
            if rest == ["power"] and method == "POST":
                act = str(body.get("action") or "")
                if act in ("suspend", "unsuspend"):
                    inst["suspended"] = act == "suspend"
                    inst["state"] = "STOPPED" if act == "suspend" else "RUNNING"
                elif act in ("start", "restart"):
                    inst["state"] = "RUNNING"
                elif act == "stop":
                    inst["state"] = "STOPPED"
                save(self.statefile)
                return self._json(200, {"ok": True, "output": f"mock {act} ok"})
            if rest == ["password"] and method == "POST":
                inst["password"] = body.get("password") or secrets.token_urlsafe(16)
                save(self.statefile)
                return self._json(200, {"ok": True, "output": "mock passwd", "password": inst["password"]})
            if rest == ["ports"] and method == "POST":
                for p in body.get("ports") or []:
                    inst["ports"].append({"public": int(p), "internal": int(p), "proto": "tcp+udp", "ssh": False})
                save(self.statefile)
                return self._json(200, {"ok": True, "output": "mock ports add"})
            if len(rest) == 2 and rest[0] == "ports" and method == "DELETE":
                pnum = int(rest[1])
                inst["ports"] = [p for p in inst["ports"] if p["public"] != pnum]
                save(self.statefile)
                return self._json(200, {"ok": True, "output": "mock ports del"})
            if rest == ["resize"] and method == "POST":
                inst.update(cpu=body.get("cpu", inst["cpu"]), ram=body.get("ram", inst["ram"]), disk=body.get("disk", inst["disk"]))
                save(self.statefile)
                return self._json(200, {"ok": True, "output": "mock resize"})
            if rest == ["reinstall"] and method == "POST":
                job = secrets.token_hex(6)
                STATE["jobs"][job] = {"id": job, "kind": "reinstall", "name": name, "status": "running", "rc": None,
                                      "output": "mock reinstall\n", "started": int(time.time()), "finished": None}
                inst["password"] = secrets.token_urlsafe(9)
                save(self.statefile)
                threading.Timer(0.4, self._finish, args=(job, 0)).start()
                return self._json(202, {"ok": True, "job": job})
            return self._json(200, {"ok": True, "output": f"mock {rest}"})

        if len(parts) == 2 and parts[0] == "jobs":
            job = STATE["jobs"].get(parts[1])
            if not job:
                return self._json(404, {"ok": False, "error": "job tidak ada"})
            return self._json(200, {"ok": True, "job": job})

        return self._json(404, {"ok": False, "error": "endpoint tidak ada"})

    def _finish(self, job: str, rc: int) -> None:
        with LOCK:
            j = STATE["jobs"].get(job)
            if j:
                j.update(status="done" if rc == 0 else "error", rc=rc, finished=int(time.time()), output=(j.get("output") or "") + "[+] mock selesai\n")
        save(self.statefile)

    def _finish_delete(self, job: str, name: str) -> None:
        with LOCK:
            STATE["instances"].pop(name, None)
        self._finish(job, 0)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8788)
    p.add_argument("--token", default="")
    p.add_argument("--state", default="/tmp/vpsnat-mock-state.json")
    a = p.parse_args()
    load(a.state)
    Handler.token = a.token
    Handler.statefile = a.state
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    srv.daemon_threads = True
    print(f"mock node listen 127.0.0.1:{a.port}", flush=True)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
