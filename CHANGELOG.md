# Changelog

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
