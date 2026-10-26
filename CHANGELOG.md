# Changelog

## 3.4.1 — 2026-10-26

Rilis kesiapan skala besar. Fokus: biaya monitor yang tadinya kuadratik, permukaan serang
web/bot, dan audit trail untuk operasi multi-admin. Schema DB tetap 25 field; tidak ada
migrasi data dan tidak ada perubahan format file.

### Performa: siklus monitor dari O(N²) menjadi O(N)

- **Batch DB (`db_cache_load`, `db_row`, `db_field_var`, `db_batch_set`/`db_batch_commit`).**
  Sebelumnya `resource_update_one` memanggil `db_field` ~8–11 kali per VPS dan setiap
  panggilan memindai seluruh file DB; tiap VPS juga menulis ulang seluruh file di bawah
  `flock`. Biaya satu siklus tumbuh kuadratik terhadap jumlah VPS. Sekarang DB dimuat sekali
  ke memori dan seluruh perubahan satu siklus diterapkan dalam **satu** penulisan ulang
  (file sementara lalu `mv`, tetap di bawah lock DB).
  Terukur pada DB sintetis: **N=100: 11,9 s → 1,8 s/siklus; N=400: 50,8 s → 5,7 s/siklus**
  (≈19 ms/VPS, linear). Sebelumnya di atas ~120 VPS interval default 15 detik tidak pernah
  tercapai sehingga auto-suspend dan kuota bandwidth menjadi basi.
- **Metrik massal satu panggilan LXD (`lxd_bulk_load`).** `lxc query /1.0/instances?recursion=2`
  mengambil status, `cpu.usage`, `memory.usage`, `limits.cpu`, dan `host_name` seluruh VPS
  sekaligus. Versi lama memanggil `lxc query .../state` + `lxc config get` per VPS per siklus.
  Bila jq/LXD tidak tersedia, otomatis kembali ke jalur lama per-VPS (perilaku identik).
- **Tanpa subprocess di hot path.** Konversi nanodetik, persentase CPU/RAM, pembandingan
  ambang (`pct_ge`), skor leaky bucket (`penalty_next_var`), dan pembacaan config
  (`conf_cache_load`/`cfg_int_var`) kini aritmetika bash/`printf -v`. Sebelumnya tiap VPS
  memicu belasan `awk`/`grep`/`cut`/`head` per siklus.
- **`vpsnat list` satu query LXD** (`vps_states_load`) alih-alih `lxc info` per baris, dan
  `vpsnat info` satu pemindaian DB (`db_row`) alih-alih 12.
- **`next_ip`** memakai satu pass awk + lookup array (dulu `grep` per kandidat IP, sampai 249 fork).
- **`next_ssh_port`** memakai `port_free_runs` yang sudah ada (dulu loop `SSH_BASE..PORT_MAX`
  dengan `awk` + `ss -lntu` untuk setiap port).
- **Cache config (`conf_get`)** menghilangkan `grep|tail|cut` berulang; `conf_set` menjaga
  cache tetap konsisten dalam proses yang sama.

### Keamanan web panel

- **CSRF lapis kedua (`origin_ok`).** Untuk auth berbasis cookie, `Origin`/`Referer` wajib
  cocok dengan header `Host`; nilai `null` ditolak. Sebelumnya hanya `X-Requested-With`,
  yang dapat dikirim request lintas-origin.
- **Rate limiter tidak bisa di-reset penyerang.** Saat melewati 10.000 entri, entri terlama
  dibuang 2.000 — bukan `clear()` seluruh counter seperti sebelumnya (mudah dipicu dengan
  membanjiri key acak, lalu brute force ulang).
- **Nama VPS divalidasi sebelum dipakai sebagai argumen CLI / URL LXD** (`need_row`,
  `safe_lxd_name`, `SAFE_NAME_RE`). Menolak nama berawalan `-` (option injection) dan
  karakter path; segmen URL LXD di-`quote()`.
- **Cache parse DB (`read_db`)** berbasis mtime+size, menghapus O(N) parse per request
  (satu request dapat memanggil `get_row` beberapa kali).

### Keamanan bot Telegram

- **Token konfirmasi 128-bit dan terikat ke user.** `secrets.token_urlsafe(16)` (dulu
  `token_hex(4)` = 32-bit) dan `_pending` menyimpan `(chat_id, user_id, argv, env, exp)`.
  Di grup, admin lain tidak lagi bisa menekan "Ya, lanjut" milik admin pertama untuk
  operasi destruktif.
- **Validasi callback terpusat (`_CB_NAME_AT`).** Semua prefix tombol yang membawa nama VPS
  divalidasi `valid_name()`; sebelumnya hanya cabang `vps:`.
- **`execute_reinstall` memvalidasi nama dan image** (`IMAGE_RE`), karena `image` dari
  callback_data diteruskan sebagai `IMG_KEY` ke CLI.
- **`_pending` dibersihkan** di `confirm_cli`, `ask_confirm_query`, dan input reinstall
  custom — sebelumnya entri konfirmasi yang tidak dipakai bocor selamanya.

### Fitur: audit trail

- **`vpsnat audit [tail [N]|search <kata>|path]`** membaca `audit.log` (JSONL, append-only,
  mode 600, rotasi satu generasi pada 10 MiB). Setiap baris memuat `ts`, `actor`, `action`,
  `target`, `result`, `detail`.
- Dicatat: create, delete, passwd, resize, clone, reinstall, set-type, set-owner, renew,
  set-expire, suspend/unsuspend (termasuk otomatis), auto-purge, port add/del,
  bandwidth set/reset, settings set, dan seluruh mutasi admin dari web panel.
- Best-effort: kegagalan menulis audit tidak pernah menggagalkan operasi bisnis.
  Password/token tidak pernah masuk audit.
- `AUDIT_LOG=0` mematikan pencatatan; `AUDIT_MAX_BYTES` mengatur batas rotasi.

### Catatan upgrade

- `vpsnat update` menjalankan `test.sh` sebelum memasang; suite kini mencakup batch DB
  (schema tetap 25 field, tidak ada baris hilang, field lain utuh), audit JSONL, dan
  kesetaraan `resource_metrics` dengan aritmetika lama.
- Verifikasi `resource_metrics` dilakukan A/B terhadap implementasi 3.4.0 pada 9 skenario
  (CPU naik/turun/idle, `prevts=0`, RAM penuh, CPU limit kosong, fallback `lxc info`):
  hasil identik.
- `vpsnat harden all` tetap disarankan setelah upgrade bila VPS lama belum menerima
  limit proses/anti-spoofing dari 3.4.0.

## 3.4.0 — 2026-10-26

Patch dari audit arsitektur v3.3.0. Hanya temuan yang terverifikasi terhadap kode yang diimplementasikan; schema DB tetap 25 field (tanpa migrasi data).

### Keamanan & ketahanan
- **Limit proses (anti fork-bomb)**: `limits.processes` per container, shared 512 dan dedicated 2048 (`vpsnat settings set proc-limit-shared|proc-limit-dedicated`, `0` = tanpa batas). Dipasang saat `create`, `clone`, `reinstall` dan diperbarui oleh `set-type`. Tidak berlaku untuk VM (LXD tidak mengenal opsi ini pada VM).
- **Anti-spoofing NIC**: `security.mac_filtering` + `security.ipv4_filtering` (dan `security.ipv6_filtering` best-effort karena bridge VPSNAT memakai `ipv6.address=none`) pada `eth0` setiap VPS. IP sudah statis per NIC (`ipv4.address`), sehingga filter bisa langsung aktif. Matikan dengan `ANTISPOOF=0` di `vpsnat.conf`.
- **`vpsnat harden [nama|all] [--check]`** (modul baru `harden.sh`): menerapkan/memeriksa limit proses dan anti-spoofing pada VPS lama. `--check` hanya melaporkan; menerapkan ke VPS berjalan meminta konfirmasi (NIC dapat terputus beberapa detik). Menu interaktif: opsi 43.
- **Guard firewall per-VPS**, dievaluasi setelah `ESTABLISHED,RELATED` (hanya koneksi baru yang diperiksa):
  - blokir SMTP outbound `25,465,587` (`settings set smtp-block 0|1`, daftar port lewat `SMTP_BLOCK_PORTS`);
  - batas koneksi baru concurrent per VPS lewat `connlimit` (`settings set conn-limit`, default 1024, `0` = nonaktif) agar satu VPS tak bisa menghabiskan tabel conntrack host.
  - Modul kernel yang tidak ada (`xt_connlimit` / `xt_multiport`) hanya melewati guard terkait dengan peringatan; firewall tetap berhasil dibangun.
- **MSS clamp** (`TCPMSS --clamp-mss-to-pmtu`) di relay dan node: konfigurasi WireGuard baru memuatnya sebagai `PostUp/PostDown`; relay/node buatan versi lama di-patch otomatis (idempoten) oleh `vpsnat restore` dan `vpsnat relay on|restart`.

### Auto-suspend shared: leaky bucket
- Sebelumnya satu sampel di bawah ambang mereset hitungan, sehingga pola "penuh 55 menit + 1 sampel idle" tidak pernah tersuspend. Kini tiap VPS shared punya skor penalti (detik) yang naik selama beban penuh dan turun `PENALTY_DECAY_PERCENT` (default 25%) dari lama sampel saat normal. Suspend saat skor ≥ `SHARED_SUSPEND_MINUTES`×60. Skor disimpan di `monitor/<nama>.penalty` (kolom DB `high_since` tidak dipakai lagi; nilai lama dimigrasikan otomatis sebagai skor awal).
- Ambang CPU = `SHARED_RESOURCE_THRESHOLD` − `SHARED_CPU_TOLERANCE` (default 2; `settings set shared-cpu-tolerance`): rata-rata CPU per 15 detik hampir tak pernah tepat 100% walau VPS memakai semua core, sehingga beban ~99% sebelumnya tidak pernah terhitung. RAM tanpa toleransi (usage cgroup dapat memuat page cache).
- Langkah per sampel dibatasi 4× interval agar jeda monitor tidak melonjakkan skor. Skor direset saat suspend/unsuspend/resize/set-type/reinstall/create/delete.
- Monitor menunggu lock alokasi paling lama `MONITOR_LOCK_TIMEOUT` (default 20 detik, sebelumnya hingga 1800 detik di belakang `create`/`clone`/`reinstall` yang panjang). Auto-suspend yang gagal karena lock otomatis dicoba lagi pada siklus berikutnya; notifikasi hanya dikirim bila VPS benar-benar tersuspend.

### Alokasi port
- Bila tidak ada satu blok kontigu yang cukup, alokasi dipecah menjadi paling banyak `PORT_SPLIT_MAX_CHUNKS` (default 3) blok kontigu dengan greedy best-fit (contoh `20014,20020-20029`). `PORT_SPLIT_MAX_CHUNKS=1` mengembalikan perilaku wajib-kontigu. Berlaku untuk `create` dan `port-add`; port internal tetap sama dengan port publik (kecuali `INT_START` eksplisit yang berurutan lintas blok).
- Pencarian port kosong kini membaca DB dan `ss` satu kali (`port_free_runs`); sebelumnya memanggil awk+ss untuk setiap port kandidat (puluhan ribu proses per alokasi).

### Preflight ruang disk
- `create`, `clone`, `snapshot create`, `backup`, dan `restore-backup` ditolak lebih awal bila ruang bebas < operasi × 1,2 + buffer 2 GB (`PREFLIGHT_BUFFER_GB`). Ruang bebas = yang lebih kecil antara sisa pool LXD dan filesystem host. Perkiraan operasi: create = image (`PREFLIGHT_CREATE_GB`, default 3; kuota disk thin-provisioned tidak dihitung penuh), clone/snapshot = pemakaian disk VPS pada pool `dir` (0 pada ZFS/Btrfs/LVM karena copy-on-write), backup = pemakaian disk VPS pada filesystem host, restore-backup = ukuran file ×2. Ruang tak terdeteksi: lanjut dengan peringatan. Matikan dengan `PREFLIGHT=0`.

### Upgrade & database
- `vpsnat upgrade` menyalin `vps.db` ke `/etc/vpsnat/backups/vps.db.pre-upgrade.v<versi>.<waktu>` (0600, `DB_BACKUP_KEEP` terbaru, default 5) **sebelum** migrasi pertama oleh kode baru. Setelah migrasi, jumlah record dan struktur diverifikasi; bila tidak cocok DB dipulihkan otomatis dari backup. Rollback runtime (`.previous`) tidak menimpa DB.
- `vpsnat db-backup [create|list]` untuk backup manual.

### Web panel
- `GET /api/me/resources` dan `GET /api/admin/vps/{nama}/resources`: hasil `lxc query .../state` di-cache 2 detik per VPS dengan single-flight; puluhan poller UI kini memakai satu subprocess per interval, bukan satu per request.
- `POST /api/admin/settings` menerima key baru: `shared-cpu-tolerance`, `proc-limit-shared`, `proc-limit-dedicated`, `conn-limit`, `smtp-block`.

### Perhatian saat upgrade
- Blokir SMTP outbound aktif secara default dan juga menutup 465/587: aplikasi di VPS yang mengirim email lewat relay SMTP eksternal akan terblokir. Gunakan `vpsnat settings set smtp-block 0` atau `SMTP_BLOCK_PORTS=25`.
- `conn-limit` 1024 berlaku untuk koneksi keluar baru dari tiap VPS (semua protokol); VPS dengan beban DNS/crawler/proxy tinggi mungkin perlu nilai lebih besar.
- VPS lama belum ter-hardening sampai menjalankan `vpsnat harden --check` lalu `vpsnat harden all`. Aturan firewall guard langsung aktif setelah `vpsnat upgrade` (yang merekonsiliasi firewall).
- Tidak diubah: pemilihan password VPS yang masih tersimpan plaintext di DB (kompatibilitas CLI lama), reinstall oleh buyer tetap nonaktif, dan lock alokasi tetap satu `.alloc.lock` (pemecahan per-VPS membutuhkan refactor `vps.sh` yang lebih besar).

### Tes
- `test.sh`: alokasi port multi-blok, guard firewall (urutan rule, toggle, kernel tanpa modul), leaky bucket (duty-cycle, toleransi CPU, migrasi `high_since`, retry saat lock gagal), hardening dengan `lxc` palsu, preflight, backup DB, MSS clamp, settings baru.
- `test_web.py`: cache resource single-flight dan key settings hardening.

## 3.3.0 — 2026-10-13

### Ditambahkan
- **PWA**: web panel kini bisa dipasang sebagai aplikasi (manifest `/manifest.webmanifest`, service worker `/sw.js`, ikon PNG dibuat otomatis oleh `web.py`). Butuh HTTPS. Service worker hanya men-cache shell halaman, manifest, dan ikon; semua `/api/*` tidak pernah di-cache. Ada tombol "Pasang aplikasi", banner offline, layar offline, dan notifikasi versi baru. CSP ditambah `manifest-src 'self'; worker-src 'self'`.
- **`get.sh` (Bash URL)**: install atau update ke commit terbaru dengan satu perintah `curl -fsSL .../get.sh | sudo bash` (opsi `--check`, `--force`; env `VPSNAT_REPO`, `VPSNAT_BRANCH`, `VPSNAT_REF`, `VPSNAT_SKIP_TESTS`). Berfungsi juga untuk instalasi lama yang belum punya `vpsnat update`.
- Dokumentasi API lengkap di README dan tab **API** pada panel: autentikasi, kode status, job, parameter tiap endpoint, contoh curl yang bisa disalin, pencarian endpoint, serta endpoint user `/api/me*`.

### Relay multi-node
- **Satu relay, banyak node**: `vpsnat relay node-add <label> [min-max]` di relay mengalokasikan IP tunnel dan slice port (default 5000 port) lalu mencetak token; `vpsnat relay join <token>` di node menyelesaikan pemasangan tanpa bolak-balik. Tambahan: `node-list`, `node-del`, `slice`. Node baru/dihapus diterapkan live tanpa restart tunnel node lain.
- `join` membatasi alokasi port VPS node ke slice-nya (`NODE_PORT_MIN/MAX`, dibaca `core.sh`) dan mengisi `PUBLIC_IP` dengan IP relay; `detach` mengembalikannya.
- `node-add`/`peer-add` menghindari port VPS milik host relay sendiri (atau slice host dari `relay slice`) dan menolak range yang bentrok, agar VPS lokal tidak dialihkan ke node.
- `peer-add` menerima range dan label opsional. Relay mode lama (1 node, seluruh range) harus `detach` + `init` ulang.

### UI
- Dark mode otomatis mengikuti perangkat, token warna konsisten, focus ring, area aman (safe area) untuk HP.
- Sheet detail VPS sebagai dialog (Esc/klik latar menutup, scroll terkunci); kartu VPS bisa dibuka dengan keyboard.
- Placeholder loading, empty state, tab mobile muat tanpa scroll, input 16px agar iOS tidak zoom, sheet layar penuh di HP.
- Gagal jaringan ditangani dengan pesan jelas; polling job dilanjutkan otomatis setelah koneksi kembali.

### Diubah
- **Ubah OS (reinstall) oleh buyer dinonaktifkan**: tombol Reinstall dihapus dari panel user dan `POST /api/me/reinstall` selalu membalas 403. Admin tetap bisa reinstall lewat `POST /api/admin/vps/{name}/reinstall`.

### Tes
- `test_web.py` menguji manifest, service worker, ikon, dan CSP; `test.sh` memeriksa `get.sh`.

## 3.2.5 — 2026-10-12

### Security & reliability hardening
- Create/reinstall no longer remove disk quota as a startup fallback; effective disk size is checked before the guest can proceed.
- Legacy SSH port reservations are included in allocation conflict checks.
- Lifecycle, port, expiry, and firewall mutations use shared locks; firewall updates stage and validate rules before switching active chains.
- Duration inputs are bounded before arithmetic; invalid dates and overflow-sized values are rejected.
- Web validators reject fractional/non-finite values and invalid booleans. Request framing, body deadlines, server worker count, and job persistence/recovery are hardened.
- Create/resize/clone/reinstall/port changes validate postconditions and preserve reservations or suspension on uncertain failure.
- Upgrade failures now attempt runtime rollback. Sync-recovered guests stay suspended pending manual review.


## 3.2.4 — 2026-10-12

### Perbaikan jumlah port Web
- Panel mengirim jumlah port create sebagai argumen CLI eksplisit dan tetap mempertahankan `NPORTS` untuk kompatibilitas.
- CLI memprioritaskan jumlah port eksplisit, memeriksa jumlah hasil alokasi, serta memverifikasi jumlah port unik setelah disimpan ke DB.
- Bila jumlah port tersimpan tidak sesuai, proses create dibatalkan dan DB/guest dibersihkan agar bug tidak diam-diam menghasilkan VPS dengan port kurang.
- Tes web menegaskan input 50 diteruskan langsung ke argumen CLI; tes shell memeriksa guard integritas alokasi.

## 3.2.3 — 2026-10-12

### Diperbaiki
- Renewal tidak lagi membuka suspension manual/resource; hanya suspension dengan alasan `expired` yang dibuka otomatis setelah expiry diperpanjang.
- Masa tenggang expiry kini berlaku walaupun VPS sudah disuspend karena alasan lain; alasan suspension tetap dipertahankan, dan unsuspend menolak VPS yang masih expired.
- Perubahan tipe layanan tidak lagi menghapus alasan suspension.
- Resize/create/reinstall memeriksa hasil perubahan disk; resize mencoba mengembalikan CPU/RAM jika resize disk gagal. Create dibatalkan jika konfigurasi disk atau setup password/SSH gagal.
- Alokasi port/SSH dikunci lintas proses pada create, port-add, clone, dan sync untuk mencegah dua operasi memilih port yang sama.
- Upgrade runtime memakai staging dan wrapper CLI atomik, serta mencoba memulihkan runtime sebelumnya jika pergantian folder gagal.

### Ditambahkan
- `vpsnat update [--check|--force]` mengambil versi dan SHA commit dari GitHub, menguji source dari commit yang sama sebelum memasang, dan mencatat commit terakhir yang berhasil dipasang.
- README menjelaskan cara update langsung dari repository dan cara update checkout lokal.
- Tes regresi untuk mempertahankan suspension manual setelah renewal serta memeriksa updater/lock.

## 3.2.2 — 2026-10-12

### Diperbaiki
- **Port hanya terbuka 1 saat membuat VPS**: `create` memakai `read -a` pada output `alloc_ports` (satu port per baris), sehingga hanya port SSH yang tersimpan di DB dan diteruskan lewat iptables. Sekarang memakai `mapfile` dan memvalidasi jumlah port yang dialokasikan. VPS lama yang sudah terlanjur dibuat dengan bug ini: tambahkan port aplikasi dengan `vpsnat port-add NAMA tcp JUMLAH` (atau tombol "Tambah port" di web).
- Web admin: "Endpoint tidak ditemukan" saat hapus port dengan kolom kosong/bukan angka (sekarang pilihan port lewat dropdown + validasi 422), dan saat membuka VPS hasil `sync`/import yang namanya memakai huruf besar, titik, atau underscore. Pesan 404 kini menyebut method dan path.
- Web admin: semua aksi per-VPS memakai nama VPS dari sheet yang sedang tampil (`data-n`), bukan variabel global, sehingga tidak bisa lagi mengirim ke `/api/admin/vps/null/...`. Jika VPS sudah terhapus saat refresh, sheet otomatis ditutup.

### Catatan upgrade
- Salin file baru ke server dengan `sudo bash vpsnat upgrade` (menyalin `web.py`/`web.html` ke `/etc/vpsnat/web/` dan restart service).

### Ditambahkan
- Jumlah port saat membuat VPS naik dari 2-10 menjadi **2-50** (termasuk 1 port SSH) di CLI (`VPS_PORTS_MAX`), web (form + API `ports`), dan dibatasi konsisten. `GET /api/admin/vps` memuat `limits.ports_min/ports_max`.
- Web admin: dashboard ringkasan (total, running, stopped, suspend, expired ≤ 7 hari, alokasi CPU/RAM/disk, bandwidth), kartu VPS dengan bar bandwidth dan sisa hari expired, pencarian dan filter status, tabel port dengan tombol salin dan ringkasan jumlah port, persentase pemakaian di tab Host.
- Test: regresi alokasi port (`test.sh`), batas 2-50, route port-del, nama legacy, dan pesan 404 (`test_web.py`).

## 3.2.1 — 2026-10-11

### Diperbaiki
- Web admin: semua aksi per-VPS (power, suspend, resize, renew, expire, password, owner, tipe, bandwidth, port, reinstall, hapus) gagal "VPS tidak ditemukan" karena UI mengirim ke `/api/admin/vps/null/...` setelah detail VPS dibuka.
- Web admin: timer polling resource menumpuk di tiap refresh; respons lambat tab VPS/Host bisa menimpa tab lain; tombol Salin tidak berfungsi di HTTP biasa (tanpa HTTPS); baris sampah `=== VPSNAT Settings ===` di kartu Setting; sesi habis kembali ke login tanpa pesan.
- Web: user ter-logout di tengah reinstall miliknya sendiri (password berubah saat job berjalan), sehingga tidak sempat melihat password baru.
- Web: koneksi keep-alive rusak setelah error 404/413 pada request yang membawa body.
- Web: login dengan identifier berupa digit non-ASCII (mis. `²`) menghasilkan error 500.
- `bandwidth set` pada VPS yang sedang stop gagal dan membiarkan flag kuota/firewall tidak diperbarui; `bandwidth show` dan `list` menampilkan kuota dalam byte berlabel GB.

### Keamanan
- Login web ditolak untuk VPS dengan password kosong atau `unknown` (placeholder hasil `sync`); sebelumnya siapa pun yang tahu nama/port SSH-nya bisa masuk dan mengambil alih VPS itu.
- User tidak bisa reinstall VPS yang disuspend atau kuotanya habis (sebelumnya reinstall membuka suspend dan mereset kuota).
- `reinstall` tidak lagi mereset pemakaian bandwidth dan status kuota habis (celah bypass kuota).

## 3.2.0 — 2026-10-11

### Ditambahkan
- **Web panel** (`web.py`, `web.html`, `web.sh`): UI + REST API tanpa dependensi pip (stdlib Python).
  - Login admin (username/password) dan login user (nama VPS atau port SSH + password root VPS).
  - User: info VPS, resource live (CPU/RAM/disk/bandwidth), start/stop/restart, ganti password, reinstall.
  - Admin: create/delete, power, suspend, reinstall, passwd, resize, renew, expire, owner, plan, bandwidth, port, settings, sync, nodes, job.
  - API admin dengan `Authorization: Bearer <WEB_API_KEY>`.
  - Tema mengikuti website Bimxyz (light, aksen biru `#2563eb`, font Inter); nama dan logo bisa diganti (`WEB_BRAND`, `WEB_LOGO_URL`).
- `vpsnat web-setup`, `vpsnat web [on|off|restart|status|logs|key|passwd|domain|remove]`.
- `vpsnat web-domain <domain> [nginx|tunnel] [email]`: HTTPS otomatis (nginx + Let's Encrypt) atau mode Cloudflare Tunnel.
- `test_web.py`: smoke test API web dengan CLI/LXC palsu (dijalankan oleh `test.sh`).

### Diperbaiki
- `vpsnat create` non-interaktif (bot Telegram dan web) mengabaikan env `CPU`, `RAM`, `DISK` sehingga selalu 1 CPU / 1024 MB / 10 GB.

### Keamanan
- Password admin di-hash scrypt, rate-limit login, cookie `HttpOnly` + `SameSite=Strict`, header CSRF wajib, CSP ketat, sesi user dicabut saat password VPS berubah.
