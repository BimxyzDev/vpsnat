# REST API

Base URL: `https://panel.contoh.com` (semua endpoint di bawah `/api/`).
Dokumentasi hidup yang selalu sinkron: **buka halaman API di panel** atau `GET /api/openapi`.

## Autentikasi

| Cara | Header | Dipakai untuk |
|---|---|---|
| API key | `Authorization: Bearer <WEB_API_KEY>` | skrip/otomasi; tanpa cookie, tanpa `X-Requested-With` |
| Cookie sesi | `POST /api/login/admin` atau `/api/login/user` | UI panel; setiap `POST`/`DELETE` wajib `X-Requested-With: vpsnat` |

- API key dibuat/diganti dengan `sudo vpsnat web key` (ditampilkan sekali).
- Sesi: cookie HttpOnly + SameSite=Strict, umur `WEB_SESSION_HOURS` (default 12 jam).
- Body JSON maks 64 KB, harus objek, memakai `Content-Length` (chunked tidak didukung).

## Format respons

```json
{"ok": true, ...}                      // sukses
{"ok": false, "error": "pesan"}        // gagal, status HTTP sesuai
```

| Status | Arti |
|---|---|
| 200 / 202 | Berhasil / job dimulai |
| 400 | Perintah node menolak (pesan di `error`) |
| 401 | Belum login atau API key salah |
| 403 | Peran tidak sesuai, header CSRF hilang, atau fitur dinonaktifkan |
| 404 | Endpoint, server, atau job tidak ditemukan |
| 409 | Nama sudah ada atau sedang diproses job lain |
| 413 | Body > 64 KB |
| 422 | Validasi input gagal |
| 429 | Terlalu banyak percobaan login gagal |
| 500 / 503 | Kesalahan internal / node tidak terhubung / panel sibuk |

## Job (operasi panjang)

`POST /api/admin/servers`, `DELETE /api/admin/servers/{name}`, dan
`POST /api/admin/servers/{name}/reinstall` membalas `202 {"ok":true,"job":"<12 hex>"}`.
Polling tiap 2-3 detik sampai `status` bukan `running`:

```json
{"ok": true, "job": {"id": "a1b2c3d4e5f6", "kind": "create", "name": "web-01",
  "status": "running", "rc": null, "output": "", "started": 1790000000, "finished": null}}
```

`kind`: `create`, `delete`, `reinstall`.
`status`: `running`, `done`, `error`, `interrupted` (panel restart sebelum job dikirim;
ulangi operasinya).

## Sesi & auth

| Method | Path | Body | Keterangan |
|---|---|---|---|
| GET | `/api/session` | — | `{ok, brand, logo, role, name}`; `role` = `admin`/`user`/`null` |
| GET | `/api/panel` | — | info panel tanpa data sensitif (dipakai halaman login) |
| POST | `/api/login/admin` | `username`, `password` | cookie sesi |
| POST | `/api/login/user` | `identifier` (nama server atau port SSH), `password` | cookie sesi |
| POST | `/api/logout` | `{}` | cabut sesi |

## Meta

| Method | Path | Keterangan |
|---|---|---|
| GET | `/api/meta` | pilihan form: `images`, `plans`, `backends`, `limits`, `defaults`, `nodes` (admin) |

## Node (admin)

| Method | Path | Body | Keterangan |
|---|---|---|---|
| GET | `/api/admin/nodes` | — | daftar node + status online, pool port, resource host |
| POST | `/api/admin/nodes` | `name`, `wan_ip`, `url?`, `port_min?`, `port_max?`, `token?` | daftarkan node; **token dikembalikan sekali** |
| GET | `/api/admin/nodes/{mid}` | — | detail satu node |
| POST | `/api/admin/nodes/{mid}/ping` | `{}` | uji agent + perbarui resource host |
| POST | `/api/admin/nodes/{mid}/token` | `{}` | putar token (token lama langsung tidak berlaku) |
| POST | `/api/admin/nodes/{mid}/maintenance` | `maintenance?` | node tidak lagi dipilih otomatis |
| POST | `/api/admin/nodes/{mid}/ports` | `port_min`, `port_max` | perluas pool port |
| POST | `/api/admin/nodes/{mid}/update` | `url?`, `wan_ip?`, `description?` | ubah alamat/WAN IP |
| DELETE | `/api/admin/nodes/{mid}` | — | hapus dari panel (server tidak dihapus) |
| GET | `/api/admin/allocations` | — | semua alokasi port: kosong atau terpakai |
| GET | `/api/admin/dashboard` | — | ringkasan panel + node |
| POST | `/api/sync` | `{}` | tarik status semua server dari node |

## Server (admin)

| Method | Path | Keterangan |
|---|---|---|
| GET | `/api/admin/servers` | daftar server (tanpa password) |
| POST | `/api/admin/servers` | buat server (job); panel mengalokasikan port |
| GET | `/api/admin/servers/{name}` | detail + password + port |
| DELETE | `/api/admin/servers/{name}` | hapus (job); port dilepas ke pool |
| POST | `/api/admin/servers/{name}/power` | `action`: start/stop/restart/suspend/unsuspend |
| POST | `/api/admin/servers/{name}/reinstall` | `image?` (job) |
| POST | `/api/admin/servers/{name}/password` | `password?` (kosong = acak); password baru dikembalikan |
| POST | `/api/admin/servers/{name}/resize` | `cpu?`, `ram?`, `disk?` (disk tidak boleh mengecil) |
| POST | `/api/admin/servers/{name}/expire` | `value`: 30d / YYYY-MM-DD / never / 0; `relative?: true` untuk perpanjang |
| POST | `/api/admin/servers/{name}/owner` | `owner` |
| POST | `/api/admin/servers/{name}/plan` | `plan`: shared/dedicated |
| POST | `/api/admin/servers/{name}/bandwidth` | `action`: set/limit/reset, `quota_gb`, `rate_mbit` |
| POST | `/api/admin/servers/{name}/ports` | `proto?`, `count?` — port diambil dari pool panel |
| DELETE | `/api/admin/servers/{name}/ports/{port}` | lepas satu port (port SSH tidak bisa) |
| GET | `/api/admin/servers/{name}/resources` | resource live dari node |

Body `POST /api/admin/servers`:

| Field | Tipe | Default | Keterangan |
|---|---|---|---|
| `name` | string | wajib | `a-z0-9-`, awal huruf/angka, maks 31 |
| `node_id` | integer | node online pertama | node tujuan |
| `image` | string | `ubuntu22` | `ubuntu24`, `ubuntu22`, `ubuntu20`, `debian12`, `debian11`, `alma9`, `rocky9`, `alpine` |
| `cpu` / `ram` / `disk` | integer | 1 / 1024 / 10 | 1-128 / MB 128-1048576 / GB 1-10000 |
| `ports` | integer | 3 | total port termasuk 1 SSH (2-50) |
| `plan` | string | `shared` | `shared`/`dedicated` |
| `backend` | string | `container` | `container`/`vm` |
| `expire` | string | `0` | `30d`, `2w`, `1m`, `12h`, `YYYY-MM-DD`, `never`, `0` |
| `owner` | string | `-` | maks 60 karakter, tanpa `\|` |
| `nesting` | boolean | `true` | hanya container |
| `password` | string | acak | 8-64 karakter |
| `bw_quota_gb` / `bw_rate_mbit` | number | default panel | 0-1000000 / 0-100000 |

Contoh detail server:

```json
{"ok": true, "server": {"id": 1, "uuid": "a1b2c3d4e5f60718", "name": "web-01",
  "node": "node-1", "node_id": 1, "node_online": true, "owner": "budi",
  "plan": "shared", "backend": "container", "image": "ubuntu22",
  "cpu": 2, "ram": 2048, "disk": 20, "created": "2026-11-07", "expires": 1792598400,
  "suspended": false, "reason": "-", "state": "RUNNING", "host": "203.0.113.10",
  "ssh": 20000, "ports": [{"public": 20000, "internal": 22, "proto": "tcp", "ssh": true},
  {"public": 20001, "internal": 20001, "proto": "tcp+udp", "ssh": false}],
  "bw": {"used": 0, "rx": 0, "tx": 0, "quota": 0, "rate": 0, "exhausted": false},
  "password": "..."}}
```

`ram` MB, `disk` GB, `expires` epoch detik (0 = tanpa expired), `bw.*` byte (`rate` Mbps).

## Client (cookie sesi user)

| Method | Path | Keterangan |
|---|---|---|
| GET | `/api/me` | detail server sendiri + password |
| GET | `/api/me/resources` | CPU, RAM, disk, network live |
| POST | `/api/me/action` | `action`: start/stop/restart |
| POST | `/api/me/passwd` | `password?` (kosong = acak) |
| POST | `/api/me/reinstall` | 403 kecuali admin mengaktifkan `allow-user-reinstall` |
| GET | `/api/me/jobs` | job milik sendiri |

## Setting & audit (admin)

| Method | Path | Keterangan |
|---|---|---|
| GET | `/api/admin/settings` | setting panel + daftar key |
| POST | `/api/admin/settings` | `key`, `value` — key: `brand`, `node-sync-seconds`, `job-timeout`, `grace-days`, `default-ports`, `ports-min`, `ports-max`, `default-quota-gb`, `default-rate-mbit`, `allow-user-reinstall` |
| GET | `/api/admin/audit` | 100 kejadian audit terakhir |
| GET | `/api/admin/jobs` | 30 job terbaru |
| GET | `/api/admin/jobs/{jid}` | status satu job |
| GET | `/api/openapi` | dokumentasi mesin (semua endpoint terdaftar) |
| POST | `/api/openapi/example` | contoh alur curl membuat server |

## Contoh alur lengkap

```bash
export KEY=<WEB_API_KEY>; BASE=https://panel.contoh.com
H="Authorization: Bearer $KEY"

# 1. node
curl -s -H "$H" $BASE/api/admin/nodes

# 2. buat server (job)
JOB=$(curl -s -X POST -H "$H" -H 'Content-Type: application/json' \
  -d '{"name":"web-01","cpu":2,"ram":2048,"disk":20,"ports":5,"expire":"30d"}' \
  $BASE/api/admin/servers | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')

# 3. tunggu selesai
while [ "$(curl -s -H "$H" $BASE/api/jobs/$JOB | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"]["status"])')" = running ]; do sleep 3; done

# 4. kredensial SSH
curl -s -H "$H" $BASE/api/admin/servers/web-01

# 5. tambah 3 port, ganti password
curl -s -X POST -H "$H" -H 'Content-Type: application/json' -d '{"proto":"tcp","count":3}' $BASE/api/admin/servers/web-01/ports
curl -s -X POST -H "$H" -H 'Content-Type: application/json' -d '{"password":"PasswordBaru2026"}' $BASE/api/admin/servers/web-01/password

# 6. hapus
curl -s -X DELETE -H "$H" $BASE/api/admin/servers/web-01
```
