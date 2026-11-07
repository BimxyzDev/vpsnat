# Referensi CLI

`vpsnat <perintah> [argumen]`. Perintah ditandai **[P]** = panel, **[N]** = node,
**[P/N]** = keduanya.

## Pasang & peran

| Perintah | Keterangan |
|---|---|
| **[P/N]** `install-panel` | pasang control-plane (panel DB, web, bot, worker) |
| **[P/N]** `install-node` | pasang data-plane (LXD, NAT, agent) |
| **[P/N]** `setup` | interaktif: pilih peran lalu pasang |
| **[P/N]** `install` | pasang keduanya di satu host (mode lama) |
| **[P/N]** `role [panel\|node\|both]` | lihat/ubah peran host |
| **[P/N]** `doctor [panel\|node]` | ringkasan kesehatan + diagnosa |
| **[P/N]** `check` | cek dukungan virtualisasi (KVM) |
| **[P/N]** `upgrade` | pasang ulang runtime lokal + migrasi DB |
| **[P/N]** `update [--check\|--force]` | ambil source terbaru dari GitHub, tes, upgrade |
| **[P/N]** `uninstall [panel\|node\|all]` | hapus komponen (destruktif) |

## Registry node

| Perintah | Keterangan |
|---|---|
| **[N]** `node init` | siapkan identitas + cetak token |
| **[N]** `node attach <token>` | terima token dari panel |
| **[N]** `node status` | peran, token, agent, DB, host |
| **[P]** `node add <nama> <url> <wan-ip> [pool]` | daftarkan node (token dicetak) |
| **[P]** `node list` | tabel node: pool, server, status |
| **[P]** `node show <nama> [--token]` | detail satu node |
| **[P]** `node ping <nama>` | uji koneksi agent |
| **[P]** `node token <nama> [--rotate]` | lihat/putar token |
| **[P]** `node del <nama>` | hapus dari panel (server tidak dihapus) |
| **[N]** `node-agent [on\|off\|restart\|status\|logs]` | kontrol agent |

## Server (VPS client)

| Perintah | Keterangan |
|---|---|
| **[N]** `create [nama]` | buat VPS (interaktif bila nama kosong) |
| **[N]** `list` | daftar VPS di node ini |
| **[N]** `info <nama>` | detail + port + password |
| **[N]** `start\|stop\|restart <nama>` | kontrol power |
| **[N]** `suspend\|unsuspend <nama>` | suspend manual |
| **[N]** `console <nama>` / `exec <nama> <cmd>` | shell / perintah di guest |
| **[N]** `delete <nama>` | hapus permanen |
| **[N]** `resize <nama>` | ubah CPU/RAM/disk |
| **[N]** `passwd <nama>` | ganti password root |
| **[N]** `reinstall <nama> [image]` | install ulang OS |
| **[N]** `clone <nama> [baru]` | duplikat VPS |
| **[N]** `set-type <nama> shared\|dedicated` | ubah tipe layanan |
| **[N]** `stats <nama>` | resource live |
| **[N]** `host` | resource host + tabel VPS |

## Port

| Perintah | Keterangan |
|---|---|
| **[N]** `port-add <nama> <tcp\|udp\|both> <jumlah>` | tambah port (jumlah, bukan rentang) |
| **[N]** `port-del <nama> <port-publik>` | hapus satu port aplikasi |
| **[N]** `port-list <nama>` | daftar mapping |
| **[P]** `alloc [node] [--free]` | alokasi port milik panel |

## Bandwidth & resource

| Perintah | Keterangan |
|---|---|
| **[N]** `bandwidth <nama> show` | kuota, pemakaian, rate |
| **[N]** `bandwidth <nama> set <gb> <mbps>` | set kuota + limit |
| **[N]** `bandwidth <nama> limit <mbps>` | ubah limit saja |
| **[N]** `bandwidth <nama> reset` | reset counter |
| **[N]** `resource-check` | sampling sekali (dipakai monitor) |
| **[N]** `monitor [on\|off\|restart\|status\|logs]` | service monitor |
| **[P/N]** `settings [show\|set <key> <val>]` | konfigurasi |

## Expiry

| Perintah | Keterangan |
|---|---|
| **[N]** `renew <nama> <durasi>` | perpanjang dari sekarang (30d, 2w, 1m, 12h) |
| **[N]** `set-expire <nama> <durasi\|YYYY-MM-DD\|never>` | set absolut |
| **[N]** `expiring [hari]` | daftar yang segera expired |
| **[N]** `expire-check` | jalankan pemeriksaan (dipakai timer) |
| **[N]** `set-owner <nama> <label>` | label pemilik |
| **[P/N]** `grace <hari>` | masa tenggang |

## Data & perawatan (node)

| Perintah | Keterangan |
|---|---|
| **[N]** `snapshot <nama> [create\|list\|restore\|delete] [nama]` | snapshot LXD |
| **[N]** `backup <nama>` | export VPS ke `/var/backups/vpsnat` |
| **[N]** `restore-backup [file]` | import backup |
| **[N]** `restore` | terapkan ulang firewall (+ MSS clamp relay) |
| **[N]** `db-backup [create\|list]` | backup node DB |
| **[N]** `harden [nama\|all] [--check]` | limit proses + anti-spoofing |
| **[N]** `publicip [ip]` | set IP publik node |
| **[P/N]** `audit [tail [N]\|search <kata>]` | audit trail JSONL |
| **[P]** `sync` | tarik status semua server dari node |
| **[P]** `jobs [id]` | riwayat/detail job |
| **[P]** `servers [--node N]` | daftar server versi panel |

## Web panel & bot (panel)

| Perintah | Keterangan |
|---|---|
| **[P]** `web-setup [port] [user] [pass]` | pasang admin web panel |
| **[P]** `web [on\|off\|restart\|status\|logs\|key\|passwd\|domain\|remove]` | kontrol panel |
| **[P]** `web-domain <domain> [nginx\|tunnel] [email]` | domain + HTTPS |
| **[P]** `web-domain [status\|remove]` | status/lepas domain |
| **[P]** `panel status` | ringkasan panel |
| **[P]** `panel worker [once\|on\|off]` | worker job |
| **[P]** `bot-setup [token] [chat_id]` | pasang bot Telegram |
| **[P]** `bot [on\|off\|restart\|status\|logs\|remove]` | kontrol bot |

## Relay WireGuard

| Perintah | Keterangan |
|---|---|
| **[N]** `relay init` | jadikan host ini relay |
| **[N]** `relay node-add <label> [min-max]` | daftarkan node, cetak token join |
| **[N]** `relay join <token>` | (di node) tempel token relay |
| **[N]** `relay node-list \| node-del <label>` | kelola node relay |
| **[N]** `relay slice <min-max\|off>` | batasi alokasi port node |
| **[N]** `relay status \| on\|off\|restart\|logs` | kontrol relay |
| **[N]** `relay detach` | lepaskan node dari relay |

## Dashboard multi-node (relay)

| Perintah | Keterangan |
|---|---|
| **[N]** `nodes` | dashboard gabungan semua node via tunnel relay |
| **[N]** `nodes list` | node terdaftar |
| **[N]** `nodes add <label> <ip-tunnel> [port] [user]` | daftarkan node lain |
| **[N]** `nodes del <label>` | hapus dari registry |
| **[N]** `nodes label <label>` | label node ini |

## Non-interaktif

```bash
VPSNAT_NONINTERACTIVE=1 VPSNAT_YES=1 vpsnat delete web-01
```

Semua perintah menerima `VPSNAT_NONINTERACTIVE=1` (tanpa prompt; nilai dari environment)
dan `VPSNAT_YES=1` (menjawab "ya" pada konfirmasi destruktif). Panel dan agent node
memakai dua variabel ini saat memanggil CLI.
