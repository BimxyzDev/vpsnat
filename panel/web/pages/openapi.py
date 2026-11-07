#!/usr/bin/env python3
"""Panel web: dokumentasi API (dibaca UI dari /api/openapi).

Dokumentasi ini adalah sumber tunggal untuk tab API di panel. Ia dihasilkan dari
daftar endpoint yang benar-benar terdaftar di app.ROUTES, sehingga halaman API
tidak bisa "basi" (memuat endpoint yang sudah tidak ada).
"""
from __future__ import annotations

import re

import app
import db
from app import ApiError, SETTING_KEYS, route

# Deskripsi per endpoint: method + pola → (ringkas, field body, contoh body, catatan)
DOC: dict[tuple[str, str], dict] = {
    ("GET", "/api/session"): {"sum": "Peran sesi saat ini + branding panel."},
    ("GET", "/api/panel"): {"sum": "Info panel tanpa data sensitif (dipakai halaman login)."},
    ("POST", "/api/login/admin"): {"sum": "Login admin (cookie sesi).",
        "fields": [["username", "string", "ya", "Username dari web-setup"], ["password", "string", "ya", "Password admin"]],
        "example": '{"username":"admin","password":"PasswordKuat123"}',
        "note": "401 salah, 429 terlalu banyak gagal, 503 admin belum dikonfigurasi."},
    ("POST", "/api/login/user"): {"sum": "Login client dengan nama server atau port SSH + password root.",
        "fields": [["identifier", "string", "ya", "Nama server atau port SSH"], ["password", "string", "ya", "Password root server"]],
        "example": '{"identifier":"web-01","password":"PasswordRoot123"}'},
    ("POST", "/api/logout"): {"sum": "Cabut sesi dan hapus cookie."},
    ("GET", "/api/meta"): {"sum": "Pilihan form: image, plan, backend, batas resource, daftar node (admin)."},
    ("GET", "/api/admin/dashboard"): {"sum": "Ringkasan panel: jumlah node/server, alokasi resource, port kosong, resource host tiap node."},
    ("GET", "/api/admin/nodes"): {"sum": "Daftar node + status online, pool port, dan resource host."},
    ("POST", "/api/admin/nodes"): {"sum": "Daftarkan node baru. Token dikembalikan sekali di respons ini.",
        "fields": [["name", "string", "ya", "a-z0-9-, maks 31"], ["url", "string", "tidak", "URL agent, default http://<wan_ip>:8788"],
                   ["wan_ip", "string", "ya", "IPv4 node — IP yang dipakai client untuk SSH"], ["port_min / port_max", "integer", "tidak", "Pool port node (default 20000-24999)"],
                   ["token", "string", "tidak", "Token dari `vpsnat node init`; kosong = panel membuat baru"]],
        "example": '{"name":"node-1","wan_ip":"203.0.113.10","url":"http://203.0.113.10:8788","port_min":20000,"port_max":24999}'},
    ("POST", "/api/admin/nodes/{mid}/ping"): {"sum": "Uji koneksi ke agent node dan perbarui resource host."},
    ("POST", "/api/admin/nodes/{mid}/token"): {"sum": "Putar token node (token lama langsung tidak berlaku)."},
    ("POST", "/api/admin/nodes/{mid}/maintenance"): {"sum": "Aktifkan/nonaktifkan maintenance: node tidak lagi dipilih otomatis saat buat server."},
    ("POST", "/api/admin/nodes/{mid}/ports"): {"sum": "Perluas pool port node, alokasi baru dibuat otomatis."},
    ("POST", "/api/admin/nodes/{mid}/update"): {"sum": "Ubah URL/WAN IP/keterangan node (mis. node pindah IP)."},
    ("DELETE", "/api/admin/nodes/{mid}"): {"sum": "Hapus node dari panel (server di node TIDAK dihapus)."},
    ("GET", "/api/admin/allocations"): {"sum": "Seluruh alokasi port: mana yang kosong dan mana yang dipakai server."},
    ("POST", "/api/sync"): {"sum": "Tarik status terbaru semua node + server ke panel DB."},
    ("GET", "/api/admin/servers"): {"sum": "Daftar server client (tanpa password)."},
    ("POST", "/api/admin/servers"): {"sum": "Buat server client. Panel mengalokasikan port lalu node membuat instance (job).",
        "fields": [["name", "string", "ya", "a-z0-9-, maks 31"], ["node_id", "integer", "tidak", "Kosong = node online pertama"],
                   ["image", "string", "tidak", "ubuntu22 (default), ubuntu24, debian12, alpine, …"], ["cpu / ram / disk", "integer", "tidak", "1-128 / 128-1048576 MB / 1-10000 GB"],
                   ["ports", "integer", "tidak", "Total port termasuk 1 SSH (2-50)"], ["plan", "string", "tidak", "shared | dedicated"],
                   ["backend", "string", "tidak", "container | vm"], ["expire", "string", "tidak", "30d, 2w, 1m, 12h, YYYY-MM-DD, never"],
                   ["owner", "string", "tidak", "Label pemilik, maks 60 karakter"], ["password", "string", "tidak", "8-64 karakter; kosong = acak"]],
        "example": '{"name":"web-01","cpu":2,"ram":2048,"disk":20,"ports":5,"expire":"30d"}',
        "note": "Membalas 202 dengan id job. Panel menyimpan alokasi port sebelum node membuat instance."},
    ("GET", "/api/admin/servers/{name}"): {"sum": "Detail server termasuk password root dan daftar port."},
    ("DELETE", "/api/admin/servers/{name}"): {"sum": "Hapus server (job). Alokasi port dilepas kembali ke pool."},
    ("POST", "/api/admin/servers/{name}/power"): {"sum": "Kontrol power.",
        "fields": [["action", "string", "ya", "start | stop | restart | suspend | unsuspend"]], "example": '{"action":"restart"}'},
    ("POST", "/api/admin/servers/{name}/reinstall"): {"sum": "Install ulang OS (job).",
        "fields": [["image", "string", "tidak", "Default ubuntu22"]], "example": '{"image":"debian12"}'},
    ("POST", "/api/admin/servers/{name}/password"): {"sum": "Ganti password root (kosong = acak). Password baru dikembalikan.",
        "fields": [["password", "string", "tidak", "8-64 karakter"]], "example": '{"password":"PasswordBaru2026"}'},
    ("POST", "/api/admin/servers/{name}/resize"): {"sum": "Ubah CPU/RAM/disk. Disk tidak boleh mengecil.",
        "fields": [["cpu", "integer", "tidak", "1-128"], ["ram", "integer", "tidak", "MB 128-1048576"], ["disk", "integer", "tidak", "GB, >= disk sekarang"]],
        "example": '{"cpu":4,"ram":4096,"disk":40}'},
    ("POST", "/api/admin/servers/{name}/expire"): {"sum": "Set/perpanjang masa aktif.",
        "fields": [["value", "string", "ya", "30d, 2w, 1m, 12h, YYYY-MM-DD, never, 0"],
                   ["relative", "boolean", "tidak", "true = dihitung dari sekarang (perpanjang)"]],
        "example": '{"value":"30d","relative":true}'},
    ("POST", "/api/admin/servers/{name}/owner"): {"sum": "Ubah label owner.",
        "fields": [["owner", "string", "ya", "Maks 60 karakter"]], "example": '{"owner":"budi"}'},
    ("POST", "/api/admin/servers/{name}/plan"): {"sum": "Ubah tipe layanan.",
        "fields": [["plan", "string", "ya", "shared | dedicated"]], "example": '{"plan":"dedicated"}'},
    ("POST", "/api/admin/servers/{name}/bandwidth"): {"sum": "Atur kuota/limit atau reset pemakaian.",
        "fields": [["action", "string", "ya", "set | limit | reset"], ["quota_gb", "number", "untuk set", "0 = tanpa kuota"],
                   ["rate_mbit", "number", "set/limit", "0 = tanpa limit"]],
        "example": '{"action":"set","quota_gb":500,"rate_mbit":100}'},
    ("POST", "/api/admin/servers/{name}/ports"): {"sum": "Tambah port dari pool node (dialokasikan panel).",
        "fields": [["proto", "string", "tidak", "tcp | udp | both"], ["count", "integer", "tidak", "1-500"]],
        "example": '{"proto":"tcp","count":5}'},
    ("DELETE", "/api/admin/servers/{name}/ports/{port}"): {"sum": "Lepas satu port aplikasi kembali ke pool (port SSH tidak bisa)."},
    ("GET", "/api/admin/servers/{name}/resources"): {"sum": "Resource live dari node: CPU, RAM, disk, network."},
    ("GET", "/api/admin/settings"): {"sum": "Setting panel + daftar key yang boleh diubah."},
    ("POST", "/api/admin/settings"): {"sum": "Ubah satu setting panel.",
        "fields": [["key", "string", "ya", " / ".join(SETTING_KEYS)], ["value", "string/number/boolean", "ya", "Sesuai key"]],
        "example": '{"key":"default-ports","value":"5"}'},
    ("GET", "/api/admin/audit"): {"sum": "100 kejadian audit terakhir (siapa mengubah apa)."},
    ("GET", "/api/admin/jobs"): {"sum": "30 job terbaru."},
    ("GET", "/api/admin/jobs/{jid}"): {"sum": "Status satu job. Polling sampai status bukan running."},
    ("GET", "/api/jobs"): {"sum": "Job milik pemanggil (admin: semua, client: miliknya)."},
    ("GET", "/api/jobs/{jid}"): {"sum": "Status satu job milik pemanggil."},
    ("GET", "/api/me"): {"sum": "Detail server milik client sendiri, termasuk password root."},
    ("GET", "/api/me/resources"): {"sum": "Resource live server sendiri (dari node)."},
    ("POST", "/api/me/action"): {"sum": "Start/stop/restart server sendiri.",
        "fields": [["action", "string", "ya", "start | stop | restart"]], "example": '{"action":"restart"}'},
    ("POST", "/api/me/passwd"): {"sum": "Ganti password root sendiri (kosong = acak).",
        "fields": [["password", "string", "tidak", "8-64 karakter"]], "example": '{"password":"PasswordBaru2026"}'},
    ("POST", "/api/me/reinstall"): {"sum": "Reinstall OS oleh client — hanya bila admin mengaktifkan allow-user-reinstall; selain itu 403."},
    ("GET", "/api/me/jobs"): {"sum": "Job milik client sendiri."},
}


def _doc_key(method: str, raw: str) -> tuple[str, str]:
    """Petakan pola regex route ke bentuk dokumentasi: (?P<name>...) -> {name}."""
    path = raw[1:-1] if raw.startswith("^") and raw.endswith("$") else raw
    path = re.sub(r"\(\?P<([a-zA-Z_][a-zA-Z0-9_]*)>[^)]*\)", r"{\1}", path)
    return (method, path)


def _pairs() -> list[dict]:
    items = []
    for method, rx, role, fn in app.ROUTES:
        pattern = rx.pattern
        pattern = pattern[1:-1] if pattern.startswith("^") and pattern.endswith("$") else pattern
        key = _doc_key(method, rx.pattern)
        doc = DOC.get(key, {})
        items.append({
            "method": method,
            "path": pattern,
            "role": role or "publik",
            "summary": doc.get("sum", (fn.__doc__ or "").strip().split("\n")[0] or "—"),
            "fields": doc.get("fields", []),
            "example": doc.get("example", ""),
            "note": doc.get("note", ""),
            "undocumented": key not in DOC,
        })
    return sorted(items, key=lambda x: (x["path"], x["method"]))


@route("GET", "/api/openapi")
def a_openapi(req):
    return {
        "ok": True,
        "version": app.VERSION,
        "auth": {
            "admin_key": "Header `Authorization: Bearer <WEB_API_KEY>` — untuk skrip/otomasi. Buat/ganti dengan `vpsnat web key`.",
            "cookie": "Login `/api/login/admin` atau `/api/login/user`. Sesi = cookie HttpOnly + SameSite=Strict; setiap POST/DELETE wajib header `X-Requested-With: vpsnat`.",
            "body": "Body JSON maks 64 KB, harus objek, memakai Content-Length (chunked tidak didukung).",
        },
        "codes": {
            "200": "Berhasil", "202": "Job dimulai", "400": "Perintah node menolak (pesan di error)",
            "401": "Belum login / API key salah", "403": "Peran tidak sesuai atau header CSRF hilang",
            "404": "Server/endpoint/job tidak ditemukan", "409": "Sedang diproses job lain atau nama sudah ada",
            "413": "Body > 64 KB", "422": "Validasi input gagal", "429": "Terlalu banyak percobaan login gagal",
            "500": "Kesalahan internal", "503": "Node tidak terhubung, panel sibuk, atau admin belum dikonfigurasi",
        },
        "endpoints": _pairs(),
        "counts": {"routes": len(app.ROUTES), "pages": len(app.PAGE_ROUTES)},
    }


@route("POST", "/api/openapi/example", "admin")
def a_openapi_example(req):
    """Contoh alur curl membuat server lalu memantau job."""
    return {"ok": True, "example": (
        "KEY=<WEB_API_KEY>; BASE=https://panel.contoh.com\n"
        "H='Authorization: Bearer '$KEY\n\n"
        "# 1. buat server (job)\n"
        "JOB=$(curl -s -X POST -H \"$H\" -H 'Content-Type: application/json' \\\n"
        "  -d '{\"name\":\"web-01\",\"cpu\":2,\"ram\":2048,\"disk\":20,\"ports\":5,\"expire\":\"30d\"}' \\\n"
        "  $BASE/api/admin/servers | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"job\"])')\n\n"
        "# 2. tunggu selesai\n"
        "while [ \"$(curl -s -H \"$H\" $BASE/api/jobs/$JOB | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"job\"][\"status\"])')\" = running ]; do sleep 3; done\n\n"
        "# 3. ambil detail + kredensial SSH\n"
        "curl -s -H \"$H\" $BASE/api/admin/servers/web-01"
    )}


app.page("/api-docs")(lambda: "api.html")
