# VPSNAT Manager

VPSNAT adalah manager VPS berbasis LXD + Linux NAT untuk provisioning, port forwarding, resource control, bandwidth quota, bandwidth shaping, expiry, administrasi Telegram, dan **web panel** (UI + REST API) dengan dukungan domain + HTTPS.

## Fitur

- Provisioning VPS container/VM (LXD) dengan NAT, port forwarding otomatis, dan quota bandwidth
- Model shared vs dedicated, auto-suspend, expiry, snapshot, dan relay WireGuard
- Multi-node dashboard
- Bot Telegram untuk admin
- **Web panel**: login admin dan user, resource live, reinstall, ganti password, REST API admin
- **Domain + HTTPS** otomatis (nginx + Let's Encrypt) atau Cloudflare Tunnel

## Requirement

- Ubuntu/Debian dengan akses root dan kernel yang mendukung LXD
- Python 3.8+ (untuk bot dan web panel; web panel tidak butuh paket pip)
- Port publik inbound dari provider (atau relay WireGuard)
- Opsional: domain yang A record-nya mengarah ke host untuk HTTPS

## Struktur

Semua file project berada dalam **satu folder**. Tidak ada direktori `lib/`, `bot/`, `scripts/`, atau `systemd/`, sehingga folder ini bisa di-upload sebagai satu paket ke GitHub/Codespaces.

```text
vpsnat/
├── vpsnat
├── core.sh
├── db.sh
├── network.sh
├── relay.sh
├── ports.sh
├── bandwidth.sh
├── resource.sh
├── vps.sh
├── expire.sh
├── data.sh
├── nodes.sh
├── bot.sh
├── install.sh
├── update.sh
├── settings.sh
├── cli.sh
├── bot.py
├── web.sh
├── web.py
├── web.html
├── test.sh
├── test_web.py
├── check.sh
├── vpsnat-monitor.service
├── vpsnat-restore.service
├── vpsnat-expire.service
├── vpsnat-expire.timer
├── ci.yml.example
├── config.example
├── .gitignore
├── CHANGELOG.md
├── LICENSE
└── README.md
```

## Model shared vs dedicated

- **shared**: tetap memakai batas CPU/RAM LXD. Monitor berjalan berkala; jika CPU atau RAM mencapai 100% secara terus-menerus selama threshold, VPS otomatis disuspend.
- **dedicated**: tidak terkena auto-suspend berbasis CPU/RAM. Bandwidth speed limit dapat diatur dengan `tc`.

Default auto-suspend shared: **60 menit**. Interval monitoring default: **15 detik**.

## Bandwidth

VPSNAT menyimpan pemakaian **RX + TX** per VPS dan dapat memberi quota dalam GB. Counter menggunakan statistik interface host (`/sys/class/net/.../statistics`) pada veth/tap VPS.

Contoh:

```bash
# Quota 500 GB + speed 100 Mbps
vpsnat bandwidth myvps set 500 100

# Tanpa quota, tetapi speed 200 Mbps
vpsnat bandwidth myvps set 0 200

# Lihat pemakaian
vpsnat bandwidth myvps show

# Reset quota counter
vpsnat bandwidth myvps reset
```

Rate limit memakai `tc` pada interface host VPS: egress memakai TBF, ingress memakai policing. Linux `tc` memang melakukan shaping pada egress dan policing pada ingress.

Saat quota habis, forwarding untuk IP VPS diblokir sampai quota di-reset atau diperpanjang. Renewal mereset counter quota.

## Port allocation

Tidak perlu memasukkan `20000-20010` lagi. Masukkan **jumlah port**:

```bash
vpsnat port-add myvps tcp 10
```

VPSNAT mencari range kontigu kosong, misalnya `20010-20019`, lalu melakukan mapping port publik ke port internal yang sama.

Saat membuat VPS, **jumlah port total** adalah 2-50 (default 3) dan sudah termasuk 1 port SSH. Contoh: `ports=6` → 1 port SSH + 5 port aplikasi (masing-masing TCP+UDP). Batas ini diatur oleh `VPS_PORTS_MAX` di `core.sh` (dan `PORTS_MAX` di `web.py`; ubah keduanya bersamaan). Port tambahan setelah VPS dibuat memakai `port-add` (1-500 per perintah).

## Universal Network / Relay

VPSNAT tidak mengunci provider. Mode `direct` memakai public IPv4 dan port inbound yang diberikan provider. Untuk VPS yang inbound-nya dibatasi provider, gunakan VPS relay yang dapat menerima trafik publik lalu meneruskannya melalui WireGuard.

### Direct

```text
Internet → Public IPv4 host → VPSNAT DNAT → LXD VPS
```

### Relay

Relay meneruskan TCP/UDP pada range `PORT_MIN-PORT_MAX` ke satu node VPSNAT melalui WireGuard. Node tetap memakai aturan DNAT VPSNAT yang sama.

Di relay:

```bash
vpsnat relay init
```

Di node:

```bash
vpsnat relay attach <relay-ip:port> <relay-public-key>
```

Lalu kembali ke relay:

```bash
vpsnat relay peer-add 10.250.0.2 <node-public-key>
```

Firewall provider/cloud pada relay tetap harus mengizinkan UDP port WireGuard serta TCP/UDP range publik. VPSNAT tidak dapat membuka firewall akun provider dari dalam server.

Versi 3.1 memasangkan satu relay ke satu NAT node. Beberapa NAT node dapat memakai relay yang berbeda.

## Repository

Target repository: `BimxyzDev/vpsnat`. Tree di repo sengaja dipecah per modul agar GitHub tidak bergantung pada satu file monolitik dan mudah dipelihara.

## Multi-Node Dashboard

Untuk deployment dengan beberapa node (misal: relay Linode + beberapa node NAT UpCloud/lainnya),
`vpsnat nodes` memberi ringkasan gabungan tanpa perlu SSH satu-satu ke tiap server.

Prasyarat: semua node terhubung ke **relay WireGuard yang sama** (lihat bagian Universal
Network/Relay di atas), sehingga tiap node punya IP tunnel `10.250.0.x` yang bisa saling
dijangkau tanpa membuka firewall publik. Dashboard menarik data lewat SSH ke IP tunnel
tersebut — pastikan SSH key sudah ditukar (`ssh-copy-id`) antar node sebelum didaftarkan.

Di tiap node, beri label agar mudah dikenali dashboard node lain:

```bash
vpsnat nodes label upcloud-01
```

Di node manapun (biasanya di relay/node utama), daftarkan node lain:

```bash
vpsnat nodes add upcloud-01 10.250.0.2
vpsnat nodes add upcloud-02 10.250.0.3
vpsnat nodes list
```

Lihat dashboard gabungan:

```bash
vpsnat nodes
```

Contoh output:

```text
=== VPSNAT Multi-Node Dashboard ===

LABEL          IP               CPU   RAM          DISK         TOTAL  UP     SUSP
---------------------------------------------------------------------------------
local(lokal)   103.x.x.x        128   89635/1024000M 752/10000G  12     11     1
upcloud-01     172.232.242.x    6     2100/15600M    6/638G      5      5      0
---------------------------------------------------------------------------------
Total gabungan: 17 VPS (16 running, 1 suspend)
```

Node yang tidak bisa dihubungi (mati/relay putus) ditandai `OFFLINE` dan tidak
menggagalkan tampilan node lainnya. Dashboard yang sama juga tersedia lewat bot
Telegram (`/nodes`) — hasilnya identik dengan CLI, cuma beda cara aksesnya.

## Install

Ubuntu/Debian host dengan kernel dan privilege yang mendukung LXD direkomendasikan.

```bash
git clone https://github.com/BimxyzDev/vpsnat.git
cd vpsnat
sudo bash vpsnat install
```

Dipanggil lewat `bash vpsnat ...` (bukan `./vpsnat ...`), jadi instalasi pertama tidak
bergantung pada execute-bit file di git — tidak akan pernah kena `Permission denied` atau
`command not found` walau clone dari mirror/zip yang mode filenya berubah. `cmd_install`
otomatis mem-`chmod +x` seluruh `*.sh` + `vpsnat` di `/usr/local/lib/vpsnat` dan membuat
symlink `/usr/local/bin/vpsnat`, jadi setelah instalasi pertama, command `vpsnat` biasa
(tanpa `bash`/`./`) langsung berfungsi dari mana saja.

Setelah install:

```bash
vpsnat
vpsnat list
vpsnat create
vpsnat host
vpsnat monitor status
```

## Web panel

Web panel adalah UI + REST API di atas CLI `vpsnat`. Logika provisioning tetap di modul Bash; `web.py` hanya memanggil CLI, jadi perilaku CLI, bot, dan web selalu sama. Hanya memakai stdlib Python (tanpa pip/venv).

### Setup

```bash
sudo vpsnat web-setup            # tanya port, username admin, password
sudo vpsnat web-setup 8787 admin 'PasswordKuat123'   # non-interaktif
sudo vpsnat web status
```

**Update dari repository:** gunakan `sudo vpsnat update` agar source terbaru diambil langsung dari branch `main`, dites, lalu dipasang. Untuk memastikan apakah ada update tanpa memasang perubahan, gunakan `vpsnat update --check`. Perintah `sudo bash vpsnat upgrade` tetap tersedia untuk memasang perubahan dari checkout lokal. Panel membaca `web.html` dari `/etc/vpsnat/web/`, sehingga file yang diubah secara lokal baru aktif setelah upgrade.

Setup membuat service `vpsnat-web`, hash password admin (scrypt), dan **API key** (ditampilkan sekali). Port harus 1024-65535 dan tidak boleh masuk range port VPS (`PORT_MIN-PORT_MAX`). Jika memakai `ufw`: `ufw allow 8787/tcp`.

Kelola: `vpsnat web [on|off|restart|status|logs|key|passwd|domain|remove]`

### Login

| Peran | Cara login |
|-------|-----------|
| Admin | Username + password dari `web-setup` (UI), atau header `Authorization: Bearer <API key>` (API) |
| User | Nama VPS **atau** port SSH + password root VPS |

User bisa melihat info/port/SSH, resource live (CPU, RAM, disk, bandwidth), start/stop/restart, ganti password, dan reinstall (wajib mengetik nama VPS). Admin bisa semuanya plus create, delete, suspend, resize, renew, expire, owner, plan, bandwidth, port, settings, sync, dan dashboard multi-node.

### Domain + HTTPS

```bash
# A record panel.contoh.com -> IP publik host, port 80/443 terbuka
sudo vpsnat web-domain panel.contoh.com nginx admin@contoh.com
sudo vpsnat web-domain status
sudo vpsnat web-domain remove
```

Mode `nginx` memasang nginx + certbot, membuat reverse proxy ke `127.0.0.1:<port>`, meminta sertifikat Let's Encrypt, lalu mengunci panel ke localhost (`WEB_BIND=127.0.0.1`, `WEB_TRUST_PROXY=1`). Aman dipasang berdampingan dengan nginx yang sudah ada (misal Pterodactyl) karena memakai `server_name` sendiri.

Mode `tunnel` untuk Cloudflare Tunnel: panel hanya mendengar di localhost dan membaca IP klien dari `CF-Connecting-IP`.

```bash
sudo vpsnat web-domain panel.contoh.com tunnel
# lalu tambahkan ingress di cloudflared: hostname panel.contoh.com -> http://127.0.0.1:8787
```

Untuk reverse proxy buatan sendiri yang terhubung dari **IP non-loopback**, hanya percaya header IP klien dari alamat proxy yang kamu tetapkan secara eksplisit di konfigurasi `/etc/vpsnat/vpsnat.conf`:

```text
WEB_TRUST_PROXY=1
WEB_TRUST_PROXY_IPS=10.0.0.2
WEB_IP_HEADER=X-Forwarded-For
```

Ganti `10.0.0.2` dengan IP sumber proxy yang benar. Jangan memasukkan IP klien umum atau subnet yang tidak kamu kendalikan. Tanpa daftar ini, header `X-Forwarded-For` dari koneksi non-loopback tidak dipakai untuk rate-limit/login audit. Restart web sesudah mengubah konfigurasi.

### Tampilan

Tema light dengan aksen biru `#2563eb` dan font Inter. Nama dan logo bisa diganti di `/etc/vpsnat/vpsnat.conf`:

```text
WEB_BRAND=Bimxyz Official
WEB_LOGO_URL=https://contoh.com/logo.png
```

Lalu `vpsnat web restart`. Font memakai Google Fonts dengan fallback ke font sistem.

### API admin

```bash
KEY=<API key>
curl -H "Authorization: Bearer $KEY" https://panel.contoh.com/api/admin/vps
curl -H "Authorization: Bearer $KEY" https://panel.contoh.com/api/admin/vps/myvps/resources
curl -X POST -H "Authorization: Bearer $KEY" -d '{"action":"restart"}' \
  https://panel.contoh.com/api/admin/vps/myvps/action
curl -X POST -H "Authorization: Bearer $KEY" \
  -d '{"name":"demo","cpu":2,"ram":2048,"disk":20,"image":"ubuntu22","plan":"shared","expire":"30d"}' \
  https://panel.contoh.com/api/admin/vps
```

| Method | Path | Keterangan |
|--------|------|-----------|
| GET | `/api/admin/host` | info host dan hitungan VPS |
| GET / POST | `/api/admin/vps` | daftar / buat VPS (job) |
| GET / DELETE | `/api/admin/vps/{n}` | detail + password / hapus (job) |
| GET | `/api/admin/vps/{n}/resources` | CPU, RAM, disk, network |
| POST | `/api/admin/vps/{n}/action` | `start` `stop` `restart` `suspend` `unsuspend` |
| POST | `/api/admin/vps/{n}/reinstall` | `{image}` (job) |
| POST | `/api/admin/vps/{n}/passwd` | `{password?}` kosong = random |
| POST | `/api/admin/vps/{n}/resize` | `{cpu, ram, disk}` |
| POST | `/api/admin/vps/{n}/renew` | `{duration}` contoh `30d` |
| POST | `/api/admin/vps/{n}/expire` | `{value}` contoh `2026-12-31`, `never` |
| POST | `/api/admin/vps/{n}/owner` | `{owner}` |
| POST | `/api/admin/vps/{n}/plan` | `{plan}` `shared` / `dedicated` |
| POST | `/api/admin/vps/{n}/bandwidth` | `{action: set/limit/reset, quota_gb, rate_mbit}` |
| POST / DELETE | `/api/admin/vps/{n}/ports[/{port}]` | `{proto, count}` / hapus port |
| GET / POST | `/api/admin/settings` | lihat / ubah setting |
| POST | `/api/admin/sync` | sinkronkan DB dengan LXD |
| GET | `/api/admin/nodes` | dashboard multi-node |
| GET | `/api/admin/jobs[/{id}]` | status job |

Operasi panjang (create, delete, reinstall) mengembalikan `202 {"job":"<id>"}`; polling `/api/admin/jobs/<id>` sampai `status` bukan `running`. Respons selalu JSON `{"ok": true|false, ...}`; error berisi `error`.

### Keamanan web panel

- Password admin di-hash scrypt; API key minimal 32 karakter.
- Login dibatasi 5 gagal per IP per 15 menit (per VPS 20), sesi HttpOnly + SameSite=Strict, sesi user dicabut saat password VPS berubah.
- Request mutasi lewat cookie wajib header `X-Requested-With: vpsnat` (proteksi CSRF); API key tidak memakai cookie.
- CSP ketat, `X-Frame-Options: DENY`, HSTS saat HTTPS.
- Input divalidasi ketat dan CLI dipanggil tanpa shell.
- **Jangan expose tanpa HTTPS.** Tanpa TLS, password lewat jaringan dalam bentuk plaintext. Pakai `vpsnat web-domain` atau reverse proxy TLS sendiri.
- Login user memakai password root VPS yang tersimpan di DB. Jika password diubah langsung dari dalam VPS (`passwd`), DB tidak ikut berubah dan login panel gagal; ganti lewat panel atau CLI.
- Sesi disimpan di memori; restart service membuat semua sesi logout.

## Telegram bot

```bash
sudo vpsnat bot-setup
sudo vpsnat bot status
```

Bot memakai `python-telegram-bot` di virtualenv `/etc/vpsnat/bot/venv` dan hanya menjadi UI untuk CLI. Logika provisioning tetap berada di modul Bash.

## Perbaikan jumlah port saat create

Panel mengirim nilai jumlah port tervalidasi ke CLI melalui argumen eksplisit serta environment `NPORTS`. CLI mengecek jumlah port unik yang benar-benar tersimpan di database; jika tidak cocok dengan permintaan (misalnya input 5 tetapi hanya 1 tersimpan), proses create dibatalkan dan tidak dilaporkan sukses. Setelah menimpa file source, jalankan `sudo bash vpsnat upgrade` dari folder repository agar runtime CLI dan file web di `/etc/vpsnat/web/` ikut diperbarui.

## Update dari GitHub

Updater mengambil SHA commit dan nomor versi dari repository GitHub `BimxyzDev/vpsnat` (branch `main`), mengunduh source pada commit tersebut, menjalankan `test.sh`, lalu menjalankan proses upgrade hanya jika tes lulus. SHA yang berhasil dipasang dicatat di `/etc/vpsnat/source.commit`, agar pemeriksaan update tidak hanya bergantung pada nomor versi.

```bash
# Cek versi/commit terbaru, tanpa mengubah instalasi
vpsnat update --check

# Ambil, tes, dan pasang source terbaru
sudo vpsnat update

# Paksa pasang ulang commit terbaru yang sama
sudo vpsnat update --force
```

Updater membutuhkan koneksi internet serta `curl`, `tar`, dan Python 3. Source baru diuji sebelum pemasangan. `install_runtime_tree` menyiapkan staging directory dan mempertahankan runtime sebelumnya sebagai `/usr/local/lib/vpsnat.previous` jika perlu pemulihan. Untuk instalasi lama yang belum memiliki command `update`, jalankan `git pull` di checkout sumber lalu `sudo bash vpsnat upgrade` satu kali. Setelah itu gunakan updater. Untuk pengembangan lokal yang belum di-push, `sudo bash vpsnat upgrade` tetap memasang checkout lokal; command itu tidak mengambil source dari GitHub.

## Testing

```bash
./test.sh        # syntax Bash/Python, unit CLI, dan smoke test API web (CLI/LXC palsu)
python3 test_web.py
```

## Monitoring

Service monitor:

```bash
sudo vpsnat monitor status
sudo vpsnat monitor logs
sudo vpsnat resource-check
```

Konfigurasi:

```text
SHARED_SUSPEND_MINUTES=60
RESOURCE_SAMPLE_SECONDS=15
SHARED_RESOURCE_THRESHOLD=100
```

Semua setting dapat diubah tanpa menyunting file konfigurasi manual:

```bash
vpsnat settings show
vpsnat settings set shared-suspend-minutes 60
vpsnat settings set shared-threshold 100
vpsnat settings set monitor-interval 15
vpsnat settings set bandwidth-default-quota 500
vpsnat settings set bandwidth-default-rate 100
```

Resource percentage dihitung terhadap resource yang dialokasikan. CPU menggunakan delta CPU time LXD terhadap interval sampling dan jumlah vCPU; memory menggunakan memory usage terhadap limit. LXD mengekspos CPU, memory, dan network usage pada state/resources instance.

## Database compatibility

Database versi lama tetap digunakan. Saat startup/install/upgrade, field tambahan akan otomatis ditambahkan tanpa menghapus data lama.

## Security notes

- File DB/config diberi mode `0600`.
- Operasi yang memodifikasi DB memakai `flock`.
- Bot hanya menerima user dalam `TG_ADMIN`.
- Web panel: lihat bagian *Keamanan web panel*. Jangan commit `vpsnat.conf` atau `vps.db` (sudah ada di `.gitignore`).
- Token callback bot mempunyai TTL.
- Password VPS masih tersimpan pada DB untuk kompatibilitas CLI lama; untuk deployment publik, batasi permission host dengan ketat.

## Disclaimer

VPSNAT memodifikasi firewall, network namespace, storage, dan LXD instances. Uji di staging sebelum diterapkan ke node produksi. Pastikan host memiliki akses console/out-of-band sebelum mengubah jaringan.


### Recovery safety note (3.2.5)

When `vpsnat sync` discovers a guest that exists in LXD but has no database record, it imports the guest with `sync-pending` reason and keeps it suspended. Inspect the IP, SSH port, disk limit, and firewall mapping before re-enabling it with `sudo vpsnat unsuspend NAME`. This avoids exposing an orphan guest using guessed allocation metadata.
