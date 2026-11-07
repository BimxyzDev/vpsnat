#!/usr/bin/env python3
"""Klien HTTP untuk agent NODE (data-plane).

Panel berbicara ke node lewat protokol JSON sederhana di atas HTTP:

    Authorization: Bearer <token node>

Semua endpoint berada di bawah /api/v1. Panel selalu menjadi pihak yang
memulai koneksi (poll & perintah), sehingga node tidak perlu bisa menjangkau
panel dan tidak ada port masuk ke panel yang harus dibuka untuk node.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request

AGENT_PREFIX = "/api/v1"


class NodeError(Exception):
    """Kegagalan komunikasi / penolakan dari node."""

    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


class NodeClient:
    def __init__(self, url: str, token: str, timeout: float = 30.0):
        self.url = (url or "").rstrip("/")
        self.token = token or ""
        self.timeout = timeout

    # -- internal --
    def _call(self, method: str, path: str, body: dict | None = None, timeout: float | None = None):
        if not self.url:
            raise NodeError("URL node belum diatur")
        data = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url + AGENT_PREFIX + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read() or b""
            status = exc.code
        except urllib.error.URLError as exc:
            raise NodeError(f"node tidak dapat dihubungi: {exc.reason}") from exc
        except (TimeoutError, OSError) as exc:
            raise NodeError(f"koneksi ke node gagal: {exc}") from exc
        try:
            payload = json.loads(raw.decode("utf-8", "replace") or "{}")
        except ValueError:
            payload = {"ok": False, "error": f"respons node bukan JSON (HTTP {status})"}
        if status >= 400 or payload.get("ok") is False:
            raise NodeError(str(payload.get("error") or f"HTTP {status}"), status)
        return payload

    # -- system --
    def system(self, timeout: float = 12.0) -> dict:
        return (self._call("GET", "/system", timeout=timeout) or {}).get("system", {})

    def health(self) -> dict:
        return self._call("GET", "/health", timeout=6.0)

    # -- instances --
    def instances(self) -> list[dict]:
        return (self._call("GET", "/instances", timeout=25.0) or {}).get("instances", [])

    def instances_map(self) -> dict[str, dict]:
        """Peta nama -> instance. Detail (termasuk password) diambil sekali per node."""
        out: dict[str, dict] = {}
        for item in self.instances():
            name = item.get("name")
            if not name:
                continue
            try:
                out[name] = self.instance(name)
            except NodeError:
                out[name] = item
        return out

    def instance(self, name: str) -> dict:
        return (self._call("GET", f"/instances/{name}") or {}).get("instance", {})

    def create(self, payload: dict) -> str:
        return str((self._call("POST", "/instances", payload, timeout=90.0) or {}).get("job", ""))

    def delete(self, name: str) -> str:
        return str((self._call("DELETE", f"/instances/{name}", timeout=90.0) or {}).get("job", ""))

    def power(self, name: str, action: str) -> dict:
        return self._call("POST", f"/instances/{name}/power", {"action": action}, timeout=120.0)

    def reinstall(self, name: str, image: str) -> str:
        return str((self._call("POST", f"/instances/{name}/reinstall", {"image": image}, timeout=90.0) or {}).get("job", ""))

    def resize(self, name: str, cpu: int, ram: int, disk: int) -> dict:
        return self._call("POST", f"/instances/{name}/resize", {"cpu": cpu, "ram": ram, "disk": disk}, timeout=300.0)

    def password(self, name: str, password: str | None = None) -> dict:
        return self._call("POST", f"/instances/{name}/password", {"password": password or ""}, timeout=120.0)

    def expire(self, name: str, value: str) -> dict:
        return self._call("POST", f"/instances/{name}/expire", {"value": value}, timeout=60.0)

    def owner(self, name: str, owner: str) -> dict:
        return self._call("POST", f"/instances/{name}/owner", {"owner": owner}, timeout=60.0)

    def plan(self, name: str, plan: str) -> dict:
        return self._call("POST", f"/instances/{name}/plan", {"plan": plan}, timeout=180.0)

    def bandwidth(self, name: str, action: str, quota_gb=0, rate_mbit=0) -> dict:
        return self._call(
            "POST",
            f"/instances/{name}/bandwidth",
            {"action": action, "quota_gb": quota_gb, "rate_mbit": rate_mbit},
            timeout=120.0,
        )

    def ports_add(self, name: str, proto: str, count: int, ports: list[int] | None = None) -> dict:
        body: dict = {"proto": proto, "count": count}
        if ports:
            body["ports"] = ports
        return self._call("POST", f"/instances/{name}/ports", body, timeout=120.0)

    def ports_del(self, name: str, port: int) -> dict:
        return self._call("DELETE", f"/instances/{name}/ports/{port}", timeout=120.0)

    def resources(self, name: str) -> dict:
        return (self._call("GET", f"/instances/{name}/resources", timeout=20.0) or {}).get("res", {})

    # -- jobs --
    def job(self, jid: str) -> dict:
        return (self._call("GET", f"/jobs/{jid}", timeout=20.0) or {}).get("job", {})

    def jobs(self) -> list[dict]:
        return (self._call("GET", "/jobs", timeout=20.0) or {}).get("jobs", [])
