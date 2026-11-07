# Pasang & rawat PANEL

Panel adalah **control-plane**: menyimpan semua data client (nama, kredensial, IP + port
SSH, alokasi port), menjalankan web UI + REST API, bot Telegram, dan worker job. Panel
tidak menjalankan LXD dan tidak ada VPS client di sini, jadi cukup VPS kecil.

## Kebutuhan

- Ubuntu/Debian, akses root
- Python 3.8+ (tanpa pip/venv untuk panel)
- 2 GB RAM cukup untuk ratusan client (beban utama: SQLite + HTTP)
- Port publik untuk panel (default `8787`) atau domain untuk HTTPS

## 1. Pasang

```bash
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-panel.sh | sudo bash
```

Dari clone lokal:

```bash
git clone https://github.com/BimxyzDev/vpsnat.git && cd vpsnat
sudo bash scripts/install-panel.sh
```

Installer mengunduh commit terbaru, menjalankan `tests/test.sh`, lalu memasang:

- `/usr/local/lib/vpsnat/` — seluruh paket (`lib/`, `panel/`, `node/`)
- `/usr/local/bin/vpsnat` — wrapper CLI
- `/etc/vpsnat/panel.db` — panel DB (SQLite, mode 0600)
- `/etc/vpsnat/role` — berisi `panel`
- `vpsnat-panel-worker.timer` — worker job tiap 20 detik

Opsi environment: `VPSNAT_REPO`, `VPSNAT_BRANCH`, `VPSNAT_REF`, `VPSNAT_SKIP_TESTS=1`.

## 2. Buat admin web

```bash
sudo vpsnat web-setup                      # interaktif
sudo vpsnat web-setup 8787 admin 'PasswordKuat123'   # non-interaktif
```

Perintah ini menyalin paket panel ke `/etc/vpsnat/web`, menulis unit `vpsnat-panel`,
membuat hash password admin (scrypt), dan **API key** (ditampilkan sekali — simpan).

Panel aktif di `http://IP-PANEL:8787`. Jika memakai ufw: `ufw allow 8787/tcp`.

## 3. HTTPS (disarankan)

```bash
# A record panel.contoh.com -> IP panel, port 80/443 terbuka
sudo vpsnat web-domain panel.contoh.com nginx admin@contoh.com
sudo vpsnat web-domain status
```

Mode `nginx` memasang nginx + certbot, membuat reverse proxy ke `127.0.0.1:<port>`,
meminta sertifikat Let's Encrypt, lalu mengunci panel ke localhost
(`WEB_BIND=127.0.0.1`, `WEB_TRUST_PROXY=1`). Aman berdampingan dengan nginx lain
(memakai `server_name` sendiri).

Mode `tunnel` untuk Cloudflare Tunnel:

```bash
sudo vpsnat web-domain panel.contoh.com tunnel
# ingress: panel.contoh.com -> http://127.0.0.1:8787
```

Reverse proxy sendiri dari IP non-loopback: daftarkan IP-nya secara eksplisit.

```text
WEB_TRUST_PROXY=1
WEB_TRUST_PROXY_IPS=10.0.0.2
WEB_IP_HEADER=X-Forwarded-For
```

## 4. Daftarkan node

```bash
sudo vpsnat node add node-1 http://IP-NODE:8788 IP-PUBLIK-NODE 20000-24999 --token <token-dari-node>
sudo vpsnat node list
sudo vpsnat node ping node-1
```

- `IP-PUBLIK-NODE` = IP yang dipakai **client** untuk SSH (bukan IP panel).
- Pool port (`20000-24999`) adalah port yang boleh dialokasikan panel di node itu.
- Token berasal dari `sudo vpsnat node init` di node (atau `vpsnat node token node-1`
  untuk melihat/memutar dari panel).

Lewat panel web: **Node → Daftarkan node**.

## 5. Buat server client

Lewat panel: **Server → Server baru**. Atau API:

```bash
KEY=<WEB_API_KEY>; BASE=https://panel.contoh.com
curl -s -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"name":"web-01","cpu":2,"ram":2048,"disk":20,"ports":5,"expire":"30d"}' \
  $BASE/api/admin/servers
```

Balasan `202 {"job":"<id>"}`. Pantau di halaman **Job** atau `GET /api/jobs/<id>`.
Setelah selesai, kredensial SSH ada di `GET /api/admin/servers/web-01`.

## Rawat

```bash
sudo vpsnat panel status          # ringkasan panel + daftar server & node
sudo vpsnat web status            # status service panel
sudo vpsnat web logs              # log panel
sudo vpsnat sync                  # tarik status semua server dari node
sudo vpsnat panel worker once     # jalankan worker sekali (debug)
sudo vpsnat jobs                  # riwayat job
sudo vpsnat alloc --free          # port yang masih kosong
sudo vpsnat node list             # status node + pool port
```

### Update

```bash
sudo vpsnat update --check        # lihat versi/commit
sudo vpsnat update                # ambil, tes, lalu upgrade
```

Updater mengambil source dari GitHub, menjalankan tes, memasang, lalu memindahkan
runtime lama ke `/usr/local/lib/vpsnat.previous` bila perlu rollback.

### Ganti password / API key

```bash
sudo vpsnat web passwd            # password admin
sudo vpsnat web key               # API key baru (yang lama langsung tidak berlaku)
```

### Backup panel DB

Panel DB berisi kredensial client. Backup rutin:

```bash
sudo cp -a /etc/vpsnat/panel.db /var/backups/panel.db.$(date +%F)
```

Hentikan `vpsnat-panel` sesaat atau pakai `sqlite3 panel.db ".backup /path"` untuk
salinan konsisten.

## Bot Telegram (opsional)

```bash
sudo vpsnat bot-setup <token> <chat_id>
sudo vpsnat bot status
```

Bot berjalan di panel; perintah yang menyentuh mesin client diteruskan ke node.

## Troubleshooting cepat

| Gejala | Periksa |
|---|---|
| Panel tidak menyala | `journalctl -u vpsnat-panel -n 50`, port bentrok, `WEB_ADMIN_HASH` kosong |
| `0 endpoint, 0 halaman` di log | paket panel tidak lengkap di `/etc/vpsnat/web` — jalankan `vpsnat web-setup` atau `vpsnat upgrade` |
| Node selalu offline | `vpsnat node ping <nama>`; firewall 8788 hanya untuk IP panel; token cocok |
| Job tertahan `running` | worker mati: `systemctl status vpsnat-panel-worker.timer`, lalu `vpsnat panel worker once` |
| `port kosong di node ini hanya N` | pool port habis: `vpsnat node show <nama>` lalu perluas lewat panel **Node → Perluas port** |
