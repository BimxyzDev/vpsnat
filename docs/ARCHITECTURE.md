# Arsitektur

VPSNAT v4 memakai model **panel/node** seperti Pterodactyl. Dokumen ini menjelaskan
pembagian tanggung jawab, data yang dimiliki siapa, dan protokol antar keduanya.

## Dua peran

| | Panel (control-plane) | Node (data-plane) |
|---|---|---|
| Padanan Pterodactyl | `panel` | `wings` |
| Menjalankan LXD | tidak | ya (container & VM) |
| Menyimpan data client | ya (SQLite) | hanya metadata runtime (pipe DB) |
| Web UI + REST API | ya | tidak |
| Bot Telegram | ya | tidak |
| NAT / DNAT / port forwarding | tidak | ya |
| `tc` bandwidth shaping | tidak | ya |
| Monitor auto-suspend, expiry | tidak | ya |
| Agent HTTP | tidak | ya, port 8788 |
| Peran cocok untuk | VPS kecil (2 GB RAM) | server dengan CPU/RAM/disk untuk VPS client |

Satu host boleh menjalankan keduanya (`/etc/vpsnat/role` = `both`), yang merupakan
perilaku v3 dan tetap didukung.

## Alur satu permintaan "buat server"

```
1. admin → POST /api/admin/servers          (panel, HTTP)
2. panel  : validasi input
3. panel  : db.allocations_take(node_id, N) → daftar port publik
4. panel  : db.server_create(...)           → baris `servers` (state=CREATING)
5. panel  : db.allocations_assign(...)      → port ditandai milik server
6. panel  : jobs.spawn("create", ...)       → baris `jobs` (status=running)
7. panel  → 202 {job: "<12 hex>"}           (request selesai, tidak menunggu LXD)
8. worker : jobs.dispatch(job)              (timer 20 detik)
9. worker → POST /api/v1/instances          (agent node) {ports: [...], ssh_port}
10. node  : vpsnat create <nama> <nports>   (env VPSNAT_ALLOC_PORTS)
11. node  → {job: "<12 hex>"}               (job lokal di node)
12. worker: GET /api/v1/jobs/<id> tiap 2 s sampai bukan running
13. worker: db.job_save(status=done, output=...) + sync.sync_server()
14. panel : GET /api/jobs/<id> → status akhir + output
```

Poin penting:

- Panel **tidak pernah** menunggu provisioning di dalam request HTTP. Operasi 3-10 menit
  aman karena statusnya hidup di DB, bukan di memori proses.
- Port dialokasikan panel **sebelum** node membuat instance. Bila node gagal, job berakhir
  `error` dan alokasi tetap tercatat — admin bisa mengulang atau menghapus server.
- Panel restart tidak menghilangkan job: `jobs.interrupt_running()` menandai job yang
  belum sempat dikirim sebagai `interrupted`, sedangkan job yang sudah punya `node_job`
  tetap dilacak oleh `jobs.reconcile()`.

## Kepemilikan data

### Panel DB (`/etc/vpsnat/panel.db`, SQLite)

```sql
nodes(id, name UNIQUE, url, token, wan_ip, port_min, port_max,
      description, maintenance, created, last_seen, last_status, last_error, system_json)

allocations(id, node_id → nodes, port, server_id → servers, UNIQUE(node_id, port))

servers(id, uuid UNIQUE, name UNIQUE, node_id → nodes,
        owner, plan, backend, image, cpu, ram, disk, nesting,
        ssh_port, password, created, expires, suspended, reason,
        bw_quota, bw_rate, bw_rx, bw_tx, state, last_error, updated)

jobs(id, kind, target, node_id, node_job, status, rc, output, actor, started, finished)

settings(k, v)      -- brand, node_sync_seconds, default_ports, ports_max, ...
audit(id, ts, actor, action, target, result, detail)
```

- `servers.password` adalah kredensial client yang dipakai untuk login panel. Setiap
  operasi node yang mengganti password **mengembalikan** password baru, dan panel
  menyimpannya (`servers.py` → `db.server_update(name, password=...)`).
- `servers.ssh_port` + `nodes.wan_ip` adalah satu-satunya sumber "client login ke mana".
- `allocations` adalah pool port. Port yang `server_id IS NULL` bebas dipakai.

### Node DB (`/etc/vpsnat/vps.db`, pipe-delimited 25 kolom)

Milik node, dipakai CLI Bash: `name|ip|ssh|cpu|ram|disk|ports|password|created|backend|
expires|owner|suspended|plan|quota|rx|tx|rate|quota_susp|high_since|cpu_prev|sample_ts|
bw_prev_rx|bw_prev_tx|reason`.

Node memakainya untuk DNAT, auto-suspend, expiry, dan bandwidth. Panel **tidak** membaca
file ini — panel hanya berbicara lewat agent.

## Protokol panel → node

Prefix `/api/v1`, JSON, `Authorization: Bearer <token node>`.

| Method | Path | Guna |
|---|---|---|
| GET | `/health` | liveness |
| GET | `/system` | hostname, public IP, CPU/RAM/disk, versi LXD, hitungan VPS |
| GET | `/instances` | daftar instance + state + bw |
| GET | `/instances/{name}` | detail (termasuk password) |
| POST | `/instances` | buat instance (job) |
| DELETE | `/instances/{name}` | hapus instance (job) |
| GET | `/instances/{name}/resources` | CPU/RAM/disk/network live |
| POST | `/instances/{name}/power` | start/stop/restart/suspend/unsuspend |
| POST | `/instances/{name}/reinstall` | install ulang OS (job) |
| POST | `/instances/{name}/resize` | ubah CPU/RAM/disk |
| POST | `/instances/{name}/password` | ganti password root |
| POST | `/instances/{name}/expire` | set/perpanjang masa aktif |
| POST | `/instances/{name}/owner` | ubah label owner |
| POST | `/instances/{name}/plan` | shared/dedicated |
| POST | `/instances/{name}/bandwidth` | set/limit/reset |
| POST | `/instances/{name}/ports` | tambah port (daftar port dari panel) |
| DELETE | `/instances/{name}/ports/{port}` | hapus satu port |
| GET | `/jobs`, `/jobs/{id}` | status job di node |

Aturan yang harus dijaga saat mengubah kontrak:

1. **Ubah `node/agent.py` dan `panel/nodeclient.py` bersamaan**, termasuk urutan argumen.
2. Operasi panjang = job (balas id), operasi cepat = balasan langsung.
3. Agent tidak pernah memanggil panel; tidak ada inbound ke panel dari node.

## Struktur kode

```text
bin/vpsnat                 # entry: siapkan VPSNAT_APP_DIR, source lib/bootstrap.sh, main "$@"
lib/bootstrap.sh           # source core → node → panel → system → cli
lib/core/core.sh           # VERSION, path, log, lock, conf, peran (vpsnat_role/role_is_*)
lib/core/db.sh             # DB node (pipe-delimited), cache, batch write
lib/node/vps.sh            # create/delete/start/resize/... (LXD)
lib/node/network.sh        # alokasi port/IP, bridge, iptables chains
lib/node/resource.sh       # sampling resource, leaky bucket, monitor loop
lib/panel/registry.sh      # pembungkus CLI untuk panelctl.py
lib/system/install.sh      # runtime tree, systemd node, upgrade, uninstall
lib/system/panel.sh        # install-panel, worker, panel status
lib/system/node.sh         # install-node, agent unit, node status
lib/system/web.sh          # salin paket panel ke /etc/vpsnat/web + unit
lib/cli/cli.sh             # router perintah + menu
```

### Kenapa `panel/app.py` tipis

`app.py` hanya `import panelapp; panelapp.main()`. Alasannya: modul halaman meng-
`import app`, dan bila `app.py` dijalankan sebagai skrip ia bernama `__main__`, sehingga
`import app` akan mengeksekusi file itu **sekali lagi** sebagai modul terpisah — router
dan registry halaman jadi dua objek berbeda, dan gejalanya server hidup dengan
`0 endpoint, 0 halaman`. Memisahkan `panelapp.py` membuat hanya ada satu objek modul.

## Keamanan antar komponen

- Token agent (`/etc/vpsnat/node.json`, kolom `nodes.token`) adalah satu-satunya
  kredensial node. Rotasi lewat `vpsnat node token <nama> --rotate` lalu
  `vpsnat node attach` di node.
- Batasi port 8788 dengan firewall ke IP panel saja.
- Panel tidak membuka port untuk node; tidak ada koneksi masuk dari node.
- Semua validasi input ada di panel (`panelapp.v_*`), lalu diulang di agent
  (`node/agent.py` `v_*`) karena agent juga punya permukaan serang sendiri.
