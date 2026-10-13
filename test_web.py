#!/usr/bin/env python3
"""Smoke test web panel dengan CLI/LXC palsu. Jalankan: python3 test_web.py"""
import http.client
import http.cookiejar
import json
import concurrent.futures
import stat
import os
import socket
import struct
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
    check("nama dengan trailing newline ditolak", call(a, "POST", "/api/admin/vps", {"name": "newline\n"}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("password dengan trailing newline ditolak", call(a, "POST", "/api/admin/vps", {"name": "passnewline", "password": "GoodPass123\n"}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("setting key tidak valid", call(a, "POST", "/api/admin/settings", {"key": "x;rm", "value": "1"})[0], 422)
    st, d = call(a, "POST", "/api/admin/vps", {"name": "newone", "cpu": 4, "ram": 4096, "disk": 30, "image": "ubuntu24"})
    check("create job", st, 202)
    j = wait_job(a, "/api/admin/jobs", d["job"])
    check("create env CPU diteruskan", "CPU=4" in j["output"], True)
    check("create default 3 port", "NPORTS=3" in j["output"], True)
    st, d = call(a, "POST", "/api/admin/vps", {"name": "bigports", "ports": 50})
    check("create 50 port diterima", st, 202)
    job50 = wait_job(a, "/api/admin/jobs", d["job"])
    check("create 50 port diteruskan lewat env", "NPORTS=50" in job50["output"], True)
    check("create 50 port diteruskan eksplisit ke CLI", "ARGS: create bigports 50" in job50["output"], True)

    # Dua request untuk nama yang sama harus memiliki satu pemenang saja.
    barrier = __import__("threading").Barrier(2)
    def racing_create():
        op = opener()
        barrier.wait(timeout=5)
        return call(op, "POST", "/api/admin/vps", {"name": "racer", "ports": 5}, hdr={"Authorization": "Bearer " + KEY})
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        race_results = list(pool.map(lambda _: racing_create(), range(2)))
    race_codes = sorted(st for st, _ in race_results)
    check("dua create serentak nama sama tidak dobel", race_codes, [202, 409])
    for st_race, race_data in race_results:
        if st_race == 202:
            race_job = wait_job(a, "/api/admin/jobs", race_data["job"])
            check("race create job selesai", race_job["status"], "done")
    state_file = os.path.join(tmp, "web-jobs.json")
    check("job state tersimpan", os.path.isfile(state_file), True)
    if os.path.isfile(state_file):
        check("permission job state private", stat.S_IMODE(os.stat(state_file).st_mode), 0o600)
    check("create 51 port ditolak", call(a, "POST", "/api/admin/vps", {"name": "toomany", "ports": 51})[0], 422)
    check("create 1 port ditolak (min 2)", call(a, "POST", "/api/admin/vps", {"name": "toofew", "ports": 1})[0], 422)
    check("fractional port count ditolak", call(a, "POST", "/api/admin/vps", {"name": "floatport", "ports": 5.9}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("boolean bukan integer port count", call(a, "POST", "/api/admin/vps", {"name": "boolport", "ports": True}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("nesting string false ditolak", call(a, "POST", "/api/admin/vps", {"name": "neststr", "nesting": "false"}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("duration overflow ditolak", call(a, "POST", "/api/admin/vps", {"name": "bigdur", "expire": "999999999999d"}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("expiry tanggal tidak valid ditolak", call(a, "POST", "/api/admin/vps", {"name": "baddate", "expire": "2026-99-99"}, hdr={"Authorization": "Bearer " + KEY})[0], 422)
    check("angka non-finite JSON ditolak", call(a, "POST", "/api/admin/vps/demo/action", {"action": float("nan")}, hdr={"Authorization": "Bearer " + KEY})[0], 400)
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
    raw = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    raw.sendall((f"GET /api/session HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}" ).encode())
    raw_resp = raw.recv(4096); raw.close()
    check("GET body ditolak agar framing proxy konsisten", b"400 Bad Request" in raw_resp, True)

    # Duplicate CL and oversize declared body must close request as malformed, without reading a giant body.
    raw = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    raw.sendall((f"POST /api/admin/vps/demo/action HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nAuthorization: Bearer {KEY}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}" ).encode())
    raw_resp = raw.recv(4096); raw.close()
    check("duplicate Content-Length ditolak", b"400 Bad Request" in raw_resp, True)
    raw = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    raw.sendall((f"POST /api/admin/vps/demo/action HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nAuthorization: Bearer {KEY}\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\nConnection: close\r\n\r\n" ).encode())
    raw_resp = raw.recv(4096); raw.close()
    check("oversized Content-Length ditolak sebelum baca body", b"413 " in raw_resp, True)

    hc = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    hc.request("POST", "/api/admin/vps/Bad_Name/action", body=b'{"action":"stop"}', headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    r1 = hc.getresponse(); r1.read()
    hc.request("GET", "/api/session"); r2 = hc.getresponse(); r2.read()
    check("keep-alive sehat setelah 404 ber-body", (r1.status, r2.status), (404, 200))
    check("API key salah", call(anon, "GET", "/api/admin/vps", hdr={"Authorization": "Bearer nope"})[0], 401)

    # PWA: manifest, service worker, ikon, dan CSP yang memperbolehkannya
    def raw(path):
        r = urllib.request.urlopen(B + path, timeout=5)
        return r.status, r.headers, r.read()
    st, h, body = raw("/manifest.webmanifest")
    mf = json.loads(body)
    check("manifest PWA", (st, h.get_content_type(), mf["display"], mf["name"], mf["short_name"]), (200, "application/manifest+json", "standalone", "Test Brand Panel", "Test Brand"))
    check("manifest ikon 192 dan 512", sorted(i["sizes"] for i in mf["icons"]), ["192x192", "512x512"])
    st, h, body = raw("/sw.js")
    check("service worker disajikan", (st, h.get_content_type(), b"vpsnat-" in body, b"%V%" in body), (200, "text/javascript", True, False))
    check("service worker scope root", h.get("Service-Worker-Allowed"), "/")
    check("service worker tidak men-cache /api/", b"startsWith('/api/')" in body, True)
    for path, size in (("/icon-192.png", 192), ("/icon-512.png", 512), ("/apple-touch-icon.png", 180)):
        st, h, body = raw(path)
        check("ikon " + path, (st, h.get_content_type(), body[:8], struct.unpack(">II", body[16:24])), (200, "image/png", b"\x89PNG\r\n\x1a\n", (size, size)))
    st, h, body = raw("/")
    csp = h.get("Content-Security-Policy", "")
    check("CSP mengizinkan manifest + worker same-origin", ("manifest-src 'self'" in csp, "worker-src 'self'" in csp), (True, True))
    check("HTML memuat link manifest", b'rel="manifest"' in body, True)
    check("path PWA tak dikenal 404", call(anon, "GET", "/icon-999.png")[0], 404)
    for i in range(6):
        r = call(opener(), "POST", "/api/login/user", {"identifier": "demo", "password": f"w{i}"})
    check("rate limit login", r[0], 429)
finally:
    srv.terminate()
    srv.wait(timeout=5)

# A detached descendant holding the output pipe must not defeat the parent command timeout.
detached_pidfile = os.path.join(tmp, "detached.pid")
detached_script = os.path.join(tmp, "spawn-detached.py")
write(detached_script, "#!/usr/bin/env python3\nimport subprocess,sys,time\nchild=subprocess.Popen([sys.executable,'-c','import time; time.sleep(15)'],start_new_session=True)\nopen(sys.argv[1],'w').write(str(child.pid))\ntime.sleep(15)\n", 0o755)
runner = subprocess.run([sys.executable, "-c", "import sys,time; sys.path.insert(0,sys.argv[1]); import web; t=time.monotonic(); rc,out=web.run_proc([sys.executable,sys.argv[2],sys.argv[3]],timeout=0.2); print(rc); print(time.monotonic()-t)", ROOT, detached_script, detached_pidfile], cwd=ROOT, env=env, capture_output=True, text=True, timeout=12)
check("timeout process group tetap bounded saat descendant detach", runner.returncode == 0 and runner.stdout.splitlines()[0] == "124" and float(runner.stdout.splitlines()[1]) < 8.0, True)
try:
    with open(detached_pidfile) as pidf:
        os.kill(int(pidf.read()), 15)
except (OSError, ValueError):
    pass

# Simulate a crash/restart: a persisted in-flight job is marked interrupted, never retried blindly.
recover_path = os.path.join(tmp, "recover-jobs.json")
write(recover_path, json.dumps([{
    "id": "abcdef123456", "kind": "create", "name": "crashed", "who": "test",
    "status": "running", "rc": None, "output": "", "started": int(time.time()), "finished": None
}]), 0o600)
recover_env = dict(env, VPSNAT_WEB_JOBS=recover_path)
recover = subprocess.run([sys.executable, "-c", "import web; print(web.JOBS['abcdef123456']['status'])"], cwd=ROOT, env=recover_env, capture_output=True, text=True, timeout=10)
check("job aktif saat crash dipulihkan sebagai interrupted", (recover.returncode, recover.stdout.strip()), (0, "interrupted"))
if os.path.isfile(recover_path):
    check("state recovery tetap private", stat.S_IMODE(os.stat(recover_path).st_mode), 0o600)

if fails:
    print(f"\n{len(fails)} tes gagal: {fails}")
    sys.exit(1)
print("\nAll web panel tests passed.")
