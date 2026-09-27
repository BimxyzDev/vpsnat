# VPSNAT Manager

VPSNAT adalah manager VPS berbasis LXD + Linux NAT untuk provisioning, port forwarding, resource control, bandwidth quota, bandwidth shaping, expiry, dan administrasi Telegram.

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
├── bot.sh
├── install.sh
├── settings.sh
├── cli.sh
├── bot.py
├── test.sh
├── check.sh
├── vpsnat-monitor.service
├── vpsnat-restore.service
├── vpsnat-expire.service
├── vpsnat-expire.timer
├── ci.yml.example
├── config.example
├── .gitignore
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

## Install

Ubuntu/Debian host dengan kernel dan privilege yang mendukung LXD direkomendasikan.

```bash
git clone https://github.com/BimxyzDev/vpsnat.git
cd vpsnat
sudo ./vpsnat install
```

Setelah install:

```bash
vpsnat
vpsnat list
vpsnat create
vpsnat host
vpsnat monitor status
```

## Telegram bot

```bash
sudo vpsnat bot-setup
sudo vpsnat bot status
```

Bot memakai `python-telegram-bot` di virtualenv `/etc/vpsnat/bot/venv` dan hanya menjadi UI untuk CLI. Logika provisioning tetap berada di modul Bash.

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
- Token callback bot mempunyai TTL.
- Password VPS masih tersimpan pada DB untuk kompatibilitas CLI lama; untuk deployment publik, batasi permission host dengan ketat.

## Disclaimer

VPSNAT memodifikasi firewall, network namespace, storage, dan LXD instances. Uji di staging sebelum diterapkan ke node produksi. Pastikan host memiliki akses console/out-of-band sebelum mengubah jaringan.
