# Upgrade & migrasi ke v4 (model panel/node)

v4 memisahkan **panel** (control-plane) dari **node** (data-plane). Instalasi v3 yang
menjalankan semuanya di satu host tetap bisa dipakai — host itu menjadi peran `both`.
Dokumen ini menjelaskan dua jalur: upgrade di tempat, dan pemisahan peran.

## Ringkasan yang berubah

| Hal | v3 | v4 |
|---|---|---|
| Peran | satu host | `panel`, `node`, atau `both` |
| Data client | `/etc/vpsnat/vps.db` (pipe) | `/etc/vpsnat/panel.db` (SQLite, milik panel) |
| Web panel | `web.py` + `web.html` monolitik | paket `panel/` + halaman terpisah |
| Alokasi port | node mengalokasikan sendiri | panel memilikinya (`allocations`) |
| Operasi panjang | thread di proses web | baris `jobs` + worker systemd timer |
| Struktur repo | semua file di root | `bin/ lib/ panel/ node/ scripts/ systemd/ tests/ docs/` |

Node tetap memakai `/etc/vpsnat/vps.db` sebagai keadaan runtime — file itu **tidak**
dihapus dan tidak perlu dimigrasikan.

## Jalur A — upgrade di tempat (host tunggal)

Cocok bila Anda tidak ingin memisahkan server. Hasilnya: satu host berperan `both`.

```bash
# 1. cek versi & commit
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/get.sh | sudo bash -s -- --check

# 2. upgrade (mengunduh source, menjalankan tes, memasang)
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/get.sh | sudo bash

# 3. siapkan panel DB + admin web
sudo vpsnat web-setup

# 4. impor VPS yang sudah ada ke panel DB
sudo vpsnat panel import
```

`vpsnat panel import` membaca `vps.db` di host ini dan membuat baris `servers` +
`allocations` di panel DB, memakai IP publik host sebagai WAN IP node dan rentang
`PORT_MIN-PORT_MAX` sebagai pool port.

Setelah itu buka panel, dan operasi bisa dijalankan dari panel maupun dari CLI node.

> **Catatan**: `vpsnat upgrade` memasang ulang runtime dan memigrasikan DB node.
> Perintah ini tidak menghapus VPS client.

## Jalur B — pisahkan panel dan node

Tujuan: panel di VPS kecil, node tetap di server yang menjalankan VPS client.

### 1. Siapkan panel baru

```bash
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-panel.sh | sudo bash
sudo vpsnat web-setup
sudo vpsnat web-domain panel.contoh.com nginx admin@contoh.com
```

### 2. Siapkan node (server yang sudah menjalankan VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-node.sh | sudo bash
sudo vpsnat node init          # catat token
```

VPS client yang sudah ada **tidak** tersentuh: installer hanya memasang/upgrade runtime,
menulis unit agent, dan memastikan firewall konsisten. Verifikasi:

```bash
sudo vpsnat list               # semua VPS lama masih ada
sudo vpsnat restore            # pastikan DNAT utuh
```

### 3. Daftarkan node ke panel

```bash
# di panel
sudo vpsnat node add node-1 http://IP-NODE:8788 IP-PUBLIK-NODE 20000-24999 --token <token>
sudo vpsnat node ping node-1
```

### 4. Impor data client lama ke panel

Panel perlu tahu VPS mana yang sudah ada di node, beserta port SSH-nya. Jalankan di
**panel**:

```bash
sudo vpsnat panel import --node node-1 --from http://IP-NODE:8788 --token <token>
```

Perintah ini membaca daftar instance dari agent node (bukan dari DB panel) lalu membuat
baris `servers` + `allocations` yang sesuai. Bila opsi agent tidak diberikan, ia membaca
`/etc/vpsnat/vps.db` lokal (kasus peran `both`).

Verifikasi sebelum mengumumkan:

```bash
sudo vpsnat servers                 # daftar dari panel DB
sudo vpsnat alloc --free            # sisa port pool
sudo vpsnat sync                    # tarik state terbaru dari node
```

### 5. Login client

Client lama tidak perlu diubah: mereka tetap `ssh root@IP-NODE -p PORT`. Yang berubah
hanya di mana data kredensial disimpan (panel).

## Setelah upgrade

```bash
sudo vpsnat doctor                  # ringkasan peran + kesehatan
sudo vpsnat role                    # pastikan peran sesuai
sudo vpsnat web status              # panel
sudo vpsnat node-agent status       # agent (node)
sudo vpsnat jobs                    # riwayat job
```

## Rollback

Upgrade menyimpan runtime sebelumnya:

```bash
ls -d /usr/local/lib/vpsnat.previous
sudo systemctl stop vpsnat-panel vpsnat-node
sudo rm -rf /usr/local/lib/vpsnat && sudo mv /usr/local/lib/vpsnat.previous /usr/local/lib/vpsnat
sudo systemctl daemon-reload && sudo systemctl start vpsnat-panel vpsnat-node
```

Panel DB tidak dihapus oleh rollback; ia berada di `/etc/vpsnat/panel.db` dan tidak
dibaca versi lama.

## Catatan kompatibilitas

- `/etc/vpsnat/vps.db` (node) tetap 25 kolom dan tetap dipakai node.
- `/etc/vpsnat/vpsnat.conf` tetap dipakai untuk hal tingkat daemon (`WEB_BIND`,
  `WEB_PORT`, `WEB_ADMIN_HASH`, `WEB_API_KEY`, `NODE_AGENT_PORT`). Setting bisnis
  (brand, default port, kuota default) pindah ke tabel `settings` di panel DB.
- Perintah CLI lama tetap ada; yang butuh LXD menolak berjalan di panel murni dengan
  pesan yang menyebutkan peran host.
