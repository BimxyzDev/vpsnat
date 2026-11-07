# Pasang & rawat NODE

Node adalah **data-plane** (padanan `wings`): menjalankan seluruh VPS client (LXD),
NAT/port forwarding, bandwidth shaping, monitor auto-suspend, expiry, hardening, dan
agent HTTP yang melayani perintah panel.

## Kebutuhan

- Ubuntu/Debian dengan kernel yang mendukung LXD, akses root
- CPU/RAM/disk sesuai jumlah VPS client yang akan dijual
- Port publik inbound dari provider (atau relay WireGuard untuk provider yang membatasi)
- Port `8788/tcp` untuk agent, dibuka **hanya untuk IP panel**

## 1. Pasang

```bash
curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-node.sh | sudo bash
```

Dari clone lokal: `sudo bash scripts/install-node.sh`.

Installer memasang LXD (snap), storage pool + bridge `lxdbr0` + profil `vpsnat`,
sysctl forwarding, chain firewall `VPSNAT_*`, node DB, agent, monitor, expiry, dan
restore service. Di akhir, installer mencetak **token node**.

Perintah yang dijalankan:

```bash
sudo vpsnat install-node          # sama dengan yang dipanggil script installer
sudo vpsnat check                 # cek dukungan VT-x/AMD-V (VM KVM)
```

## 2. Identitas & token

```bash
sudo vpsnat node init             # cetak nama + token node
sudo vpsnat node status           # peran, identitas, status agent
```

Token disimpan di `/etc/vpsnat/node.json` (mode 0600). Token ini yang dipakai panel
untuk memanggil agent.

## 3. Daftarkan ke panel

Dari **panel**:

```bash
sudo vpsnat node add node-1 http://IP-NODE:8788 IP-PUBLIK-NODE 20000-24999 --token <token>
```

Atau dari **node** (bila panel memberi token baru):

```bash
sudo vpsnat node attach <token>
sudo systemctl restart vpsnat-node
```

Bila IP publik node berubah, perbarui di panel: `vpsnat node show node-1` untuk
memeriksa, atau lewat panel web **Node → (ubah)**; API: `POST /api/admin/nodes/<id>/update`.

## 4. Firewall

```bash
# hanya panel yang boleh menghubungi agent
ufw allow from IP-PANEL to any port 8788 proto tcp
ufw deny 8788/tcp
```

Pool port (`20000-24999`) harus terbuka untuk client:

```bash
ufw allow 20000:24999/tcp
ufw allow 20000:24999/udp
```

## Perintah node

```bash
sudo vpsnat node status                    # peran, token, agent, DB, host
sudo vpsnat node-agent [on|off|restart|status|logs]
sudo vpsnat doctor                         # ringkasan kesehatan node
sudo vpsnat list                           # daftar VPS client di node ini
sudo vpsnat info web-01                    # detail + port + password
sudo vpsnat monitor [on|off|restart|status|logs]
sudo vpsnat settings show                  # ambang auto-suspend, hardening
sudo vpsnat harden all                     # terapkan hardening ke VPS lama
sudo vpsnat restore                        # terapkan ulang firewall
sudo vpsnat host                           # resource host + tabel VPS
```

## Menjalankan VPS client

Biasanya panel yang membuat server (lewat agent). Untuk debugging, node bisa membuat
sendiri — node lalu mengalokasikan port dari pool lokalnya:

```bash
sudo vpsnat create web-01
sudo vpsnat start web-01
sudo vpsnat port-add web-01 tcp 3
sudo vpsnat info web-01
```

Perintah dari panel mengirim **daftar port eksplisit** (`VPSNAT_ALLOC_PORTS`), jadi
node tidak mengalokasikan sendiri pada jalur panel. Jangan mencampur dua jalur untuk
server yang sama.

## Model shared vs dedicated

- **shared**: mengikuti limit CPU/RAM LXD. Monitor berkala menaikkan skor penalti saat
  beban penuh dan menurunkannya saat normal (leaky bucket); VPS disuspend bila skor
  mencapai ambang (default 60 menit).
- **dedicated**: tidak terkena auto-suspend CPU/RAM. Speed limit diatur dengan `tc`.

```bash
sudo vpsnat settings set shared-suspend-minutes 60
sudo vpsnat settings set monitor-interval 15
sudo vpsnat settings set shared-threshold 100
sudo vpsnat settings set shared-cpu-tolerance 2
```

## Hardening

| Perlindungan | Default | Pengaturan |
|---|---|---|
| Limit proses per container | shared 512, dedicated 2048 | `proc-limit-shared`, `proc-limit-dedicated` |
| Anti-spoofing NIC | aktif | `ANTISPOOF=0` di `vpsnat.conf` |
| Blokir SMTP outbound | aktif (25,465,587) | `smtp-block`, `SMTP_BLOCK_PORTS` |
| Batas koneksi baru per VPS | 1024 | `conn-limit` (0 = nonaktif) |
| MSS clamp relay & node | otomatis | — |
| Preflight ruang disk | aktif | `PREFLIGHT`, `PREFLIGHT_BUFFER_GB` |

```bash
sudo vpsnat harden --check        # laporan, tanpa mengubah
sudo vpsnat harden all            # terapkan ke semua VPS
```

Catatan: anti-spoofing memblokir paket dengan MAC/IP bukan milik VPS. VPS yang
menjalankan bridge/LXD bersarang akan terblokir; matikan dengan `ANTISPOOF=0` bila
memang dibutuhkan.

## Bandwidth

```bash
sudo vpsnat bandwidth web-01 show
sudo vpsnat bandwidth web-01 set 500 100    # kuota 500 GB, 100 Mbps
sudo vpsnat bandwidth web-01 limit 200      # ubah speed tanpa ubah kuota
sudo vpsnat bandwidth web-01 reset
```

Saat kuota habis, forwarding untuk IP VPS diblokir sampai kuota di-reset atau diperpanjang.

## Relay WireGuard (provider yang membatasi inbound)

```bash
# di relay
sudo vpsnat relay init
sudo vpsnat relay node-add node-1            # cetak token join
# di node
sudo vpsnat relay join <token>
```

Relay meneruskan port publik ke node lewat WireGuard; alokasi port node dibatasi ke
slice-nya dan `PUBLIC_IP` diset ke IP relay agar info SSH untuk client benar.

## Update & diagnosa

```bash
sudo vpsnat update --check
sudo vpsnat update
sudo vpsnat doctor
sudo vpsnat node-agent logs
sudo journalctl -u vpsnat-monitor -n 50
sudo journalctl -u vpsnat-expire -n 50
```

| Gejala | Periksa |
|---|---|
| Panel bilang node offline | `systemctl status vpsnat-node`, `ss -ltnp \| grep 8788`, token sama dengan panel |
| `create` gagal "IP habis" | `vpsnat list` — IP `10.10.10.2-250` terpakai semua |
| `create` gagal "port kosong tidak cukup" | pool port panel habis; perluas lewat panel |
| VPS tidak bisa diakses dari luar | firewall provider, `vpsnat port-list <nama>`, `vpsnat restore` |
| Auto-suspend terlalu agresif | `vpsnat settings set shared-suspend-minutes 120`, cek `vpsnat stats <nama>` |
| VM tidak bisa dibuat | `vpsnat check` — `/dev/kvm` harus ada |
