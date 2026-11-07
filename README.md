# VPSNAT Manager

Manager VPS berbasis **LXD + Linux NAT** dengan model **panel/node** seperti Pterodactyl:
satu **panel** menyimpan semua data client, dan satu atau banyak **node** menjalankan
seluruh proses VPS client.

```
                    ┌───────────────────────────────┐
   admin / client   │  PANEL (control-plane)        │
   ───────────────► │  • data client + kredensial   │
     HTTPS          │  • IP & port SSH untuk login  │
                    │  • web UI + REST API          │
                    │  • bot Telegram, worker job   │
                    └───────────┬───────────────────┘
                                │  HTTP + Bearer token (panel → node)
                    ┌───────────▼───────────────────┐
                    │  NODE (data-plane)            │
                    │  • LXD: container / VM client │
                    │  • NAT + port forwarding      │
                    │  • bandwidth, monitor, expiry │
                    │  • agent (padanan wings)      │
                    └───────────┬───────────────────┘
                                │
                        client SSH ke IP:port node
```

- **Panel** bisa VPS kecil (2 GB RAM cukup untuk ratusan client): tidak ada LXD, tidak
  ada VPS client. Kalau panel mati, VPS client tetap berjalan di node.
- **Node** menjalankan seluruh beban: LXD, DNAT, `tc`, monitor auto-suspend, expiry,
  hardening. Node tidak butuh akses masuk ke panel — panel selalu yang menghubungi node.
- **Pool port milik panel.** Panel mengalokasikan port dari `allocations` lalu mengirim
  daftar eksplisit ke node, jadi satu port tidak pernah dipakai dua client.

## Fitur

- Provisioning VPS container/VM (LXD) dengan NAT + port forwarding otomatis
- Model shared vs dedicated, auto-suspend berbasis CPU/RAM, expiry, snapshot, relay WireGuard
- **Web panel multi-halaman**: dashboard, server, detail server, node, job, setting, API docs
- **REST API** penuh + API key untuk otomasi; dokumentasi hidup di `/api-docs`
- **Bot Telegram** untuk admin (berjalan di panel)
- **PWA**: panel bisa dipasang sebagai aplikasi (butuh HTTPS), dark mode otomatis
- **Hardening**: limit proses, anti-spoofing NIC, blokir SMTP, batas koneksi, MSS clamp
- **Audit trail**: siapa mengubah apa dan kapan
- Domain + HTTPS otomatis (nginx + Let's Encrypt) atau Cloudflare Tunnel

## Pasang

### 1. Panel (control-plane)

Di VPS kecil yang akan menjadi otak sistem:

```bash
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-panel.sh | sudo bash
sudo vpsnat web-setup            # tanya port, username, password admin
```

Panel menyala di `http://IP-PANEL:8787`. Pasang domain + HTTPS:

```bash
sudo vpsnat web-domain panel.contoh.com nginx admin@contoh.com
```

### 2. Node (data-plane)

Di setiap server yang akan menjalankan VPS client (butuh kernel yang mendukung LXD):

```bash
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-node.sh | sudo bash
sudo vpsnat node init            # cetak nama + token node
```

### 3. Hubungkan node ke panel

Di **panel**:

```bash
sudo vpsnat node add node-1 http://IP-NODE:8788 IP-PUBLIK-NODE 20000-24999
# tempel token dari langkah 2 dengan opsi --token <token>
sudo vpsnat node list
sudo vpsnat node ping node-1
```

Atau dari **node** (token dari panel): `sudo vpsnat node attach <token>`.

Buka port `8788/tcp` di firewall node **hanya untuk IP panel**.

### 4. Buat VPS client

Lewat panel web (**Server → Server baru**) atau CLI di panel:

```bash
sudo vpsnat create web-01
```

Client lalu login SSH dengan:

```
ssh root@IP-PUBLIK-NODE -p PORT-SSH
```

Port SSH, IP, dan password ditampilkan di halaman detail server di panel, dan di
`vpsnat info web-01` pada node.

## Halaman panel

| Halaman | Isi |
|---|---|
| `/` | Dashboard: ringkasan server, node online, resource host tiap node |
| `/servers` | Daftar + form buat server, filter status/expiry |
| `/servers/<nama>` | Detail: info, resource live, kontrol, resize, expiry, password, bandwidth, port, reinstall, hapus |
| `/nodes` | Registry node: tambah, ping, token, maintenance, pool port, hapus |
| `/jobs` | Riwayat operasi panjang + output lengkap |
| `/settings` | Setting panel + audit trail |
| `/api-docs` | Dokumentasi API (dibaca dari router, selalu sinkron) |
| `/login` | Login admin & client |
| `/account` | Halaman client: server sendiri, resource, kontrol, ganti password |

Setiap halaman adalah berkas HTML sendiri di `panel/web/pages/` dengan JS-nya di
`panel/web/static/js/page-*.js`; CSS bersama di `panel/web/static/css/app.css`.

## Struktur repository

```text
vpsnat/
├── bin/vpsnat                 # entry point CLI (memuat lib/bootstrap.sh)
├── lib/
│   ├── bootstrap.sh           # memuat semua modul sesuai peran
│   ├── core/                  # core.sh, db.sh, audit.sh, settings.sh
│   ├── node/                  # network, vps, ports, bandwidth, resource, expire, harden, relay, data, nodes
│   ├── panel/                 # registry.sh (registry node + alokasi di panel)
│   ├── system/                # install, update, panel, node, web, bot
│   └── cli/cli.sh             # router perintah + menu
├── panel/                     # APLIKASI PANEL (Python stdlib)
│   ├── app.py                 # entry tipis → panelapp.main()
│   ├── panelapp.py            # inti: HTTP server, router, sesi, validasi, PWA
│   ├── db.py                  # SQLite panel (nodes, allocations, servers, jobs, settings, audit)
│   ├── jobs.py                # registry job panel → node
│   ├── nodeclient.py          # klien HTTP agent node
│   ├── sync.py                # tarik state/kredensial/bandwidth dari node
│   ├── worker.py              # worker job (systemd timer 20 detik)
│   ├── cli_shim.py            # perintah gaya-CLI untuk bot di panel
│   ├── panelctl.py            # utilitas control-plane (dipakai CLI Bash)
│   ├── bot.py                 # bot Telegram
│   └── web/
│       ├── pages/             # HTML per halaman + modul API (core_api, servers, nodes, openapi)
│       └── static/            # css/app.css, js/app.js, js/page-*.js
├── node/agent.py              # daemon agent node (padanan wings), port 8788
├── scripts/                   # install-panel.sh, install-node.sh, get.sh, _bootstrap.sh, check.sh
├── systemd/                   # template unit (panel, worker, node, monitor, expire, bot, restore)
├── tests/                     # test.sh (bash), test_panel.py, mock_node.py
└── docs/                      # ARCHITECTURE, INSTALL-PANEL, INSTALL-NODE, CLI, API, UPGRADE, TROUBLESHOOTING
```

## Perintah CLI

Perintah VPS (`create`, `list`, `start`, …) berjalan di **node**; di panel gunakan web/API
atau jalankan langsung di node. Perintah `node`, `web`, `bot`, `panel`, `jobs`, `sync`,
`alloc`, `servers` berjalan di **panel**.

```bash
# peran & diagnosa
vpsnat role                      # tampilkan/ubah peran host
vpsnat doctor                    # ringkasan kesehatan panel atau node
vpsnat check                     # cek dukungan virtualisasi (KVM)

# panel: registry node
vpsnat node add <nama> <url> <wan-ip> [pool]   # daftarkan node (token dicetak)
vpsnat node list | show <nama> | ping <nama> | token <nama> | del <nama>
vpsnat node init                 # (di node) identitas + token
vpsnat node attach <token>       # (di node) terima token dari panel
vpsnat alloc [node] [--free]     # alokasi port
vpsnat servers [--node N]        # daftar server versi panel
vpsnat jobs [id]                 # riwayat job
vpsnat sync                      # tarik status semua server dari node
vpsnat panel worker once         # jalankan worker sekali

# panel: web & bot
vpsnat web-setup [port] [user] [pass]
vpsnat web [on|off|restart|status|logs|key|passwd|domain|remove]
vpsnat web-domain <domain> [nginx|tunnel] [email]
vpsnat bot-setup [token] [chat_id]
vpsnat bot [on|off|restart|status|logs|remove]

# node: VPS client
vpsnat create [nama] | list | info <nama>
vpsnat start|stop|restart|suspend|unsuspend <nama>
vpsnat resize <nama> | passwd <nama> | reinstall <nama> [image]
vpsnat delete <nama> | clone <nama> [baru] | set-type <nama> shared|dedicated
vpsnat port-add <nama> <tcp|udp|both> <jumlah> | port-del <nama> <port> | port-list <nama>
vpsnat bandwidth <nama> [show|set <gb> <mbps>|limit <mbps>|reset]
vpsnat renew <nama> 30d | set-expire <nama> <30d|YYYY-MM-DD|never> | expiring [hari]
vpsnat set-owner <nama> <label>
vpsnat snapshot <nama> [create|list|restore|delete]
vpsnat backup <nama> | restore-backup [file] | stats <nama> | host
vpsnat monitor [on|off|restart|status|logs] | settings [show|set]
vpsnat harden [nama|all] [--check] | audit [tail [N]|search <kata>]

# perawatan
vpsnat update [--check|--force]  # ambil source terbaru dari GitHub, tes, lalu upgrade
vpsnat upgrade                   # pasang ulang runtime lokal + migrasi DB
vpsnat uninstall [panel|node|all]
```

Detail lengkap: [docs/CLI.md](docs/CLI.md).

## API

Semua endpoint di bawah `/api/`. Autentikasi:

- **API key** (skrip/otomasi): `Authorization: Bearer <WEB_API_KEY>` — buat dengan `vpsnat web key`.
- **Cookie sesi** (UI): login `/api/login/admin` atau `/api/login/user`; setiap
  `POST`/`DELETE` wajib header `X-Requested-With: vpsnat`.

```bash
KEY=<WEB_API_KEY>; BASE=https://panel.contoh.com

# daftar node & server
curl -s -H "Authorization: Bearer $KEY" $BASE/api/admin/nodes
curl -s -H "Authorization: Bearer $KEY" $BASE/api/admin/servers

# buat server (job) lalu pantau
JOB=$(curl -s -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"name":"web-01","cpu":2,"ram":2048,"disk":20,"ports":5,"expire":"30d"}' \
  $BASE/api/admin/servers | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')
curl -s -H "Authorization: Bearer $KEY" $BASE/api/jobs/$JOB

# detail + kredensial SSH
curl -s -H "Authorization: Bearer $KEY" $BASE/api/admin/servers/web-01
```

Dokumentasi interaktif (semua endpoint + contoh curl): buka **API** di panel, atau
`GET /api/openapi`. Rincian: [docs/API.md](docs/API.md).

## Bot Telegram

```bash
sudo vpsnat bot-setup            # token dari @BotFather + chat id admin
sudo vpsnat bot status
```

Bot berjalan di **panel** dan memakai data panel; operasi yang menyentuh mesin client
diteruskan ke node.

## Keamanan

- Password admin di-hash scrypt; API key minimal 32 karakter.
- Login dibatasi 5 gagal per IP per 15 menit (per server 20), sesi HttpOnly + SameSite=Strict.
- Request mutasi lewat cookie wajib `X-Requested-With` **dan** Origin/Referer cocok.
- CSP ketat, `X-Frame-Options: DENY`, HSTS saat HTTPS.
- Token agent node hanya bisa dipakai panel; buka port agent hanya untuk IP panel.
- **Jangan expose panel tanpa HTTPS.** Tanpa TLS, password lewat jaringan sebagai plaintext.
- File DB/config bermode `0600`; operasi tulis memakai transaksi SQLite / `flock`.

## Tes

```bash
bash tests/test.sh          # syntax semua skrip, unit CLI, struktur repo, smoke test panel
python3 tests/test_panel.py # panel + agent node tiruan: alur penuh end-to-end
```

`tests/test_panel.py` menyalakan agent node tiruan (`tests/mock_node.py`), panel
sungguhan, dan worker, lalu menguji login, registrasi node, alokasi port, create server
(job), sync, power/resize/port/password, login client, keamanan, semua halaman, dan hapus.

## Dokumentasi

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — model panel/node, skema DB, protokol agent
- [docs/INSTALL-PANEL.md](docs/INSTALL-PANEL.md) — pasang & rawat panel
- [docs/INSTALL-NODE.md](docs/INSTALL-NODE.md) — pasang & rawat node
- [docs/CLI.md](docs/CLI.md) — semua perintah CLI
- [docs/API.md](docs/API.md) — REST API
- [docs/UPGRADE.md](docs/UPGRADE.md) — upgrade & migrasi dari v3
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — diagnosa masalah umum
- [CHANGELOG.md](CHANGELOG.md) — riwayat versi

## Lisensi

MIT — lihat [LICENSE](LICENSE).

## Disclaimer

VPSNAT memodifikasi firewall, network namespace, storage, dan instance LXD. Uji di
staging sebelum dipakai di node produksi. Pastikan host punya akses console/out-of-band
sebelum mengubah jaringan.
