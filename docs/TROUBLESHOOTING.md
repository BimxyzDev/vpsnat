# Troubleshooting

## Panel

### Panel tidak mau menyala

```bash
sudo systemctl status vpsnat-panel --no-pager -n 40
sudo journalctl -u vpsnat-panel -n 80 --no-pager
```

Penyebab umum:

| Pesan / gejala | Sebab | Perbaikan |
|---|---|---|
| `Address already in use` | port dipakai proses lain | `ss -ltnp \| grep 8787`, ganti `WEB_PORT` |
| `PERINGATAN: WEB_ADMIN_HASH belum diset` | belum `web-setup` | `sudo vpsnat web-setup` |
| `0 endpoint, 0 halaman` | paket panel tidak lengkap di `/etc/vpsnat/web` | `sudo vpsnat web-setup` atau `sudo vpsnat upgrade` |
| `ModuleNotFoundError: panelapp` | `app.py` dijalankan dari folder salah | jalankan `python3 /etc/vpsnat/web/app.py`, bukan dari `/root` |

Catatan `0 endpoint`: penyebab historisnya adalah `app.py` dijalankan sebagai `__main__`
sehingga modul halaman meng-`import app` dan mengeksekusinya **dua kali** — router jadi
dua objek. v4 memisahkan `app.py` (tipis) dari `panelapp.py` (isi) untuk mencegahnya.
Bila muncul lagi, pastikan kedua file ada dan `app.py` hanya berisi `import panelapp`.

### Login admin gagal terus

- Pastikan username cocok dengan `WEB_ADMIN_USER` di `/etc/vpsnat/vpsnat.conf`.
- Reset password: `sudo vpsnat web passwd`.
- Rate limit: 5 gagal per IP per 15 menit. Tunggu atau ganti IP.

### Client tidak bisa login panel

- Login client memakai **nama server** atau **port SSH** + password root server.
- Password harus yang tersimpan di panel. Kalau password diubah langsung di dalam VPS
  (`passwd`), panel tidak tahu — ganti lewat panel atau jalankan `vpsnat sync`.
- Server hasil impor dengan password `unknown` tidak bisa login sampai password diset.

### Lupa API key

```bash
sudo vpsnat web key        # membuat yang baru; yang lama langsung tidak berlaku
```

## Node

### Node selalu offline di panel

```bash
# di node
sudo vpsnat node status
systemctl status vpsnat-node --no-pager -n 30
ss -ltnp | grep 8788
sudo vpsnat node-agent logs
```

1. Agent mendengar di `0.0.0.0:8788`? Cek `NODE_AGENT_BIND`/`NODE_AGENT_PORT`.
2. Port 8788 terbuka untuk IP panel saja (`ufw allow from IP-PANEL to any port 8788`).
3. Token sama: `vpsnat node token <nama>` di panel vs `cat /etc/vpsnat/node.json` di node.
4. URL di panel benar (`http://IP-NODE:8788`, bukan `https` bila tanpa TLS).

Perbaiki token:

```bash
# di panel
sudo vpsnat node token node-1 --rotate
# di node
sudo vpsnat node attach <token-baru>
sudo systemctl restart vpsnat-node
```

### Job tertahan `running`

```bash
systemctl status vpsnat-panel-worker.timer
sudo systemctl start vpsnat-panel-worker.timer
sudo vpsnat panel worker once      # jalankan sekali, lihat output
tail -50 /etc/vpsnat/panel-worker.log
```

Job yang tidak pernah sampai ke node ditandai `interrupted` saat panel restart; ulangi
operasinya. Job yang sudah punya `node_job` akan direkonsiliasi otomatis.

### `create` gagal: "port kosong di node ini hanya N"

Pool port panel habis. Perluas:

```bash
# lewat panel web: Node -> Perluas port
curl -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"port_min":20000,"port_max":29999}' $BASE/api/admin/nodes/1/ports
```

Pastikan juga provider/firewall node membuka rentang itu.

### `create` gagal: "IP habis"

Subnet node `10.10.10.0/24` penuh (maks ~249 VPS per node). Tambah node baru, atau ubah
`SUBNET`/`NET_PREFIX` di `lib/core/core.sh` (butuh instalasi ulang bridge).

### VPS tidak bisa diakses dari luar

```bash
# di node
sudo vpsnat port-list web-01
sudo iptables -t nat -L VPSNAT_PRE -n -v
sudo vpsnat restore
```

1. Port benar-benar terbuka di firewall **provider** (bukan hanya ufw).
2. `PUBLIC_IP` node benar (`vpsnat host`).
3. Bila memakai relay: slice port node mencakup port itu (`vpsnat relay status`).

### Auto-suspend terlalu agresif

```bash
sudo vpsnat stats web-01
sudo vpsnat settings set shared-suspend-minutes 120
sudo vpsnat settings set shared-cpu-tolerance 5
sudo vpsnat unsuspend web-01
```

Skor penalti disimpan di `/etc/vpsnat/monitor/<nama>.penalty`; naik saat beban penuh,
turun 25% per sampel normal.

### VM (KVM) tidak bisa dibuat

```bash
sudo vpsnat check
```

Butuh CPU flag `vmx`/`svm` **dan** `/dev/kvm`. Di VPS bersarang (LXC/Docker) biasanya
tidak tersedia — pakai backend container.

## Umum

### `vpsnat: command not found`

```bash
ls -l /usr/local/bin/vpsnat /usr/local/lib/vpsnat
sudo bash /usr/local/lib/vpsnat/bin/vpsnat install-panel   # atau install-node
```

### Setelah update, panel/node memakai kode lama

Runtime ada di `/usr/local/lib/vpsnat`, bukan di folder clone. Setelah mengubah file:

```bash
sudo vpsnat upgrade      # pasang ulang dari checkout lokal
sudo vpsnat update       # ambil dari GitHub
```

### Melihat audit trail

```bash
sudo vpsnat audit tail 50
sudo vpsnat audit search vps.delete
```
