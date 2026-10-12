#!/usr/bin/env python3
"""Smoke test web panel dengan CLI/LXC palsu. Jalankan: python3 test_web.py"""
import http.client
import http.cookiejar
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="vpsnat-web-test-")
DB = os.path.join(tmp, "vps.db")
CONF = os.path.join(tmp, "vpsnat.conf")
KEY = "k" * 48
ROW = "{n}|10.10.10.{i}|{ssh}|2|2048|20|tcp:{ssh}:22,tcp:{p}:{p}|{pw}|2026-10-01|container|0|{owner}|0|shared|5000000000|1000000000|500000000|10|0|0|0|0|0|0|-"


def write(path, text, mode=0o644):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


write(DB, ROW.format(n="demo", i=2, ssh=20000, p=20001, pw="UserPass12345", owner="-") + "\n"
      + ROW.format(n="other", i=3, ssh=20010, p=20011, pw="OtherPass9999", owner="<b>x</b>") + "\n"
      + ROW.format(n="susp", i=4, ssh=20020, p=20021, pw="SuspPass12345", owner="-").replace("|0|shared|", "|1|shared|", 1) + "\n"
      + ROW.format(n="synced", i=5, ssh=20030, p=20031, pw="unknown", owner="-") + "\n"
      + ROW.format(n="Legacy_VM.1", i=6, ssh=20040, p=20041, pw="LegacyPass1234", owner="-") + "\n")
write(os.path.join(tmp, "fakecli"), f"""#!/bin/bash
echo "ARGS: $* | CPU=${{CPU:-}} IMG=${{IMG_KEY:-}} YES=${{VPSNAT_YES:-}} NPORTS=${{NPORTS:-}} COUNT=${{COUNT:-}} EXT=${{EXT:-}}"
case "$1" in
  create|reinstall) sleep 1; echo "Password     : SECRETPW123"; echo "[+] done";;
  start) echo "[x] demo sedang suspended"; exit 1;;
  settings) if [ "$2" = show ]; then echo "=== VPSNAT Settings ==="; echo "GRACE_DAYS = 3"; else echo "[+] ok"; fi;;
  passwd) NEW="${{PASS:-Rand0mPass99}}"; sed -i "s/^\\(demo|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|\\)[^|]*/\\1$NEW/" {DB}; echo "[+] Password demo: $NEW";;
  *) echo "[+] ok $1";;
esac
""", 0o755)
write(os.path.join(tmp, "fakelxc"), """#!/bin/bash
[ "$1" = list ] && { echo "demo,RUNNING"; echo "other,STOPPED"; exit 0; }
N=$(date +%s%N)
echo "{\\"status\\":\\"Running\\",\\"cpu\\":{\\"usage\\":$((N%100000000000))},\\"memory\\":{\\"usage\\":300000000},\\"disk\\":{\\"root\\":{\\"usage\\":2000000000}},\\"network\\":{\\"eth0\\":{\\"counters\\":{\\"bytes_received\\":1,\\"bytes_sent\\":2}}},\\"processes\\":7}"
""", 0o755)

h = subprocess.run([sys.executable, os.path.join(ROOT, "web.py"), "hashpw"], input="AdminPass123", capture_output=True, text=True).stdout.strip()
assert h.startswith("scrypt:"), "hashpw gagal"
sock = socket.socket(); sock.bind(("127.0.0.1", 0)); PORT = sock.getsockname()[1]; sock.close()
write(CONF, f"WEB_PORT={PORT}\nWEB_BIND=127.0.0.1\nWEB_ADMIN_USER=bima\nWEB_ADMIN_HASH={h}\nWEB_API_KEY={KEY}\nPUBLIC_IP=1.2.3.4\nWEB_BRAND=Test Brand\nWEB_TRUST_PROXY=1\n")

env = dict(os.environ, VPSNAT_WEB_CONF=CONF, VPSNAT_WEB_DB=DB, VPSNAT_WEB_CLI=os.path.join(tmp, "fakecli"), VPSNAT_WEB_LXC=os.path.join(tmp, "fakelxc"))
srv = subprocess.Popen([sys.executable, os.path.join(ROOT, "web.py")], env=env, stderr=subprocess.DEVNULL)
B = f"http://127.0.0.1:{PORT}"
fails = []
XFF = {"X-Forwarded-For": "203.0.113.7"}  # IP terpisah agar tes login-gagal tidak menghabiskan rate-limit tes lain


def opener():
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def call(op, method, path, body=None, hdr=None, csrf=True):
    headers = {"Content-Type": "application/json"}
    if csrf:
        headers["X-Requested-With"] = "vpsnat"
    headers.update(hdr or {})
    data = json.dumps(body).encode() if body is not None else None
    try:
        r = op.open(urllib.request.Request(B + path, data=data, method=method, headers=headers), timeout=15)
        return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def check(label, got, want):
    ok = got == want
    print(("PASS " if ok else "FAIL ") + f"{label}: {got}" + ("" if ok else f" (harus {want})"))
    if not ok:
        fails.append(label)


def wait_job(op, base, jid):
    for _ in range(40):
        st, d = call(op, "GET", f"{base}/{jid}")
        if d.get("job", {}).get("status") != "running":
            return d["job"]
        time.sleep(0.5)
    return {"status": "timeout"}


try:
    for _ in range(40):
        try:
            urllib.request.urlopen(B + "/", timeout=2).read()
            break
        except OSError:
            time.sleep(0.25)
    anon = opener()
    st, d = call(anon, "GET", "/api/session")
    check("brand dari config", d.get("brand"), "Test Brand")
    check("admin endpoint tanpa login", call(anon, "GET", "/api/admin/vps")[0], 401)
    check("POST tanpa header CSRF", call(anon, "POST", "/api/login/user", {"identifier": "demo", "password": "x"}, csrf=False)[0], 403)
    check("login user password salah", call(anon, "POST", "/api/login/user", {"identifier": "demo", "password": "bad"})[0], 401)

    check("login ident non-ASCII digit tidak 500", call(anon, "POST", "/api/login/user", {"identifier": "\u00b2", "password": "x"}, hdr=XFF)[0], 401)
    check("login VPS hasil sync (password 'unknown') ditolak", call(anon, "POST", "/api/login/user", {"identifier": "synced", "password": "unknown"}, hdr=XFF)[0], 401)
    us = opener(); call(us, "POST", "/api/login/user", {"identifier": "susp", "password": "SuspPass12345"})
    check("user VPS suspended tidak boleh reinstall", call(us, "POST", "/api/me/reinstall", {"image": "debian12", "confirm": "susp"})[0], 403)

    u = opener()
    check("login user (nama)", call(u, "POST", "/api/login/user", {"identifier": "demo", "password": "UserPass12345"})[0], 200)
    st, d = call(u, "GET", "/api/me")
    check("me.ssh", d["vps"]["ssh"], 20000)
    check("user ke route admin", call(u, "GET", "/api/admin/vps")[0], 403)
    check("start error CLI", call(u, "POST", "/api/me/action", {"action": "start"})[1].get("error"), "demo sedang suspended")
    check("aksi tidak valid", call(u, "POST", "/api/me/action", {"action": "delete"})[0], 422)
    check("reinstall konfirmasi salah", call(u, "POST", "/api/me/reinstall", {"image": "ubuntu22", "confirm": "x"})[0], 422)
    st, d = call(u, "POST", "/api/me/reinstall", {"image": "debian12", "confirm": "demo"})
    check("reinstall job", st, 202)
    check("reinstall saat sibuk", call(u, "POST", "/api/me/reinstall", {"image": "debian12", "confirm": "demo"})[0], 409)
    job = wait_job(u, "/api/me/jobs", d["job"])
    check("job selesai", job["status"], "done")
    check("password disamarkan di log", "SECRETPW123" in job["output"], False)
    check("password format salah", call(u, "POST", "/api/me/passwd", {"password": "a b"})[0], 422)
    u_b = opener(); call(u_b, "POST", "/api/login/user", {"identifier": "20000", "password": "UserPass12345"})
    st, d = call(u, "POST", "/api/me/passwd", {"password": "NewUserPw2026"})
    check("ganti password sendiri", (st, d.get("password")), (200, "NewUserPw2026"))
    check("sesi sendiri tetap valid", call(u, "GET", "/api/me")[0], 200)
    check("sesi lain VPS sama dicabut", call(u_b, "GET", "/api/me")[0], 401)
    check("password lama ditolak", call(opener(), "POST", "/api/login/user", {"identifier": "20000", "password": "UserPass12345"})[0], 401)
    other = opener(); call(other, "POST", "/api/login/user", {"identifier": "other", "password": "OtherPass9999"})
    check("job milik user lain", call(other, "GET", "/api/me/jobs/" + job["id"])[0], 404)

    a = opener()
    check("admin password salah", call(a, "POST", "/api/login/admin", {"username": "bima", "password": "x"})[0], 401)
    check("login admin", call(a, "POST", "/api/login/admin", {"username": "bima", "password": "AdminPass123"})[0], 200)
    st, d = call(a, "GET", "/api/admin/vps")
    check("admin list", [v["name"] for v in d["vps"]], ["demo", "other", "susp", "synced", "Legacy_VM.1"])
    check("owner tetap string mentah (UI yang escape)", d["vps"][1]["owner"], "<b>x</b>")
    check("host info", "web" in call(a, "GET", "/api/admin/host")[1]["host"], True)
    check("settings tanpa key kosong dari baris header", "" in call(a, "GET", "/api/admin/settings")[1]["settings"], False)
    check("detail ada password", call(a, "GET", "/api/admin/vps/demo")[1]["vps"]["password"], "NewUserPw2026")
    check("nama tidak valid", call(a, "POST", "/api/admin/vps", {"name": "Bad Name"})[0], 422)
    check("setting key tidak valid", call(a, "POST", "/api/admin/settings", {"key": "x;rm", "value": "1"})[0], 422)
    st, d = call(a, "POST", "/api/admin/vps", {"name": "newone", "cpu": 4, "ram": 4096, "disk": 30, "image": "ubuntu24"})
    check("create job", st, 202)
    j = wait_job(a, "/api/admin/jobs", d["job"])
    check("create env CPU diteruskan", "CPU=4" in j["output"], True)
    check("create default 3 port", "NPORTS=3" in j["output"], True)
    st, d = call(a, "POST", "/api/admin/vps", {"name": "bigports", "ports": 50})
    check("create 50 port diterima", st, 202)
    check("create 50 port diteruskan", "NPORTS=50" in wait_job(a, "/api/admin/jobs", d["job"])["output"], True)
    check("create 51 port ditolak", call(a, "POST", "/api/admin/vps", {"name": "toomany", "ports": 51})[0], 422)
    check("create 1 port ditolak (min 2)", call(a, "POST", "/api/admin/vps", {"name": "toofew", "ports": 1})[0], 422)
    check("list memuat limit port", call(a, "GET", "/api/admin/vps")[1]["limits"], {"ports_min": 2, "ports_max": 50})
    check("VPS nama legacy bisa dibuka", call(a, "GET", "/api/admin/vps/Legacy_VM.1")[0], 200)
    check("VPS tidak ada -> 404 VPS", call(a, "GET", "/api/admin/vps/tidakada")[1].get("error"), "VPS tidak ditemukan.")
    check("endpoint salah menyebut path", call(a, "GET", "/api/admin/nothing")[1].get("error", "").startswith("Endpoint tidak ditemukan: GET /api/admin/nothing"), True)
    st, d = call(a, "POST", "/api/admin/vps/demo/ports", {"proto": "both", "count": 50})
    check("tambah 50 port", (st, "COUNT=50" in d.get("output", "")), (200, True))
    check("hapus port tanpa nomor -> 422 (bukan 404)", call(a, "DELETE", "/api/admin/vps/demo/ports/")[0], 422)
    check("hapus port non-angka -> 422", call(a, "DELETE", "/api/admin/vps/demo/ports/abc")[0], 422)
    st, d = call(a, "DELETE", "/api/admin/vps/demo/ports/20001")
    check("hapus port valid", (st, "EXT=20001" in d.get("output", "")), (200, True))
    check("renew format absolut ditolak", call(a, "POST", "/api/admin/vps/demo/renew", {"duration": "2026-12-31"})[0], 422)
    check("bandwidth set", call(a, "POST", "/api/admin/vps/demo/bandwidth", {"action": "set", "quota_gb": 10, "rate_mbit": 50})[1]["output"].split("|")[0].strip(), "ARGS: bandwidth demo set 10 50")
    check("admin tanpa header CSRF", call(a, "POST", "/api/admin/vps/demo/action", {"action": "stop"}, csrf=False)[0], 403)
    call(a, "POST", "/api/logout", {})
    check("setelah logout", call(a, "GET", "/api/admin/vps")[0], 401)

    k = {"Authorization": "Bearer " + KEY}
    check("API key list", call(anon, "GET", "/api/admin/vps", hdr=k)[0], 200)
    check("API key POST tanpa CSRF header", call(anon, "POST", "/api/admin/vps/demo/action", {"action": "restart"}, hdr=k, csrf=False)[0], 200)
    hc = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    hc.request("POST", "/api/admin/vps/Bad_Name/action", body=b'{"action":"stop"}', headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    r1 = hc.getresponse(); r1.read()
    hc.request("GET", "/api/session"); r2 = hc.getresponse(); r2.read()
    check("keep-alive sehat setelah 404 ber-body", (r1.status, r2.status), (404, 200))
    check("API key salah", call(anon, "GET", "/api/admin/vps", hdr={"Authorization": "Bearer nope"})[0], 401)
    for i in range(6):
        r = call(opener(), "POST", "/api/login/user", {"identifier": "demo", "password": f"w{i}"})
    check("rate limit login", r[0], 429)
finally:
    srv.terminate()
    srv.wait(timeout=5)

if fails:
    print(f"\n{len(fails)} tes gagal: {fails}")
    sys.exit(1)
print("\nAll web panel tests passed.")
