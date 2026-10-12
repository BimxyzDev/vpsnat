# Changelog

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
