#!/usr/bin/env bash

bot_write_files() {
  local src="${VPSNAT_APP_DIR}/panel/bot.py"
  mkdir -p "$BOT_DIR"
  [[ -f "$src" ]] || { err "bot.py tidak ditemukan di ${src}."; return 1; }
  install -m 700 "$src" "${BOT_DIR}/bot.py"
  # Bot berjalan di PANEL: ia memakai modul panel (DB + agent), bukan CLI LXD.
  if [[ -d "${WEB_DIR}" ]]; then
    local f
    for f in cli_shim.py db.py jobs.py nodeclient.py sync.py panelapp.py; do
      [[ -f "${WEB_DIR}/${f}" ]] && install -m 700 "${WEB_DIR}/${f}" "${BOT_DIR}/${f}"
    done
  fi
  return 0
}

bot_write_unit() {
  cat > "/etc/systemd/system/${BOT_SERVICE}.service" <<EOF2
[Unit]
Description=VPSNAT Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${BOT_DIR}
Environment=PYTHONPATH=${BOT_DIR}:${WEB_DIR}
Environment=VPSNAT_PANEL_DB=${PANEL_DB}
Environment=VPSNAT_WEB_CONF=${CONF_FILE}
Environment=VPSNAT_BOT_BACKEND=panel
ExecStart=${BOT_DIR}/venv/bin/python ${BOT_DIR}/bot.py
Restart=always
RestartSec=5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

bot_setup() {
  need_root
  require_panel_role || return 1
  local token="${1:-}" admin="${2:-}" me
  panel_db_init >/dev/null 2>&1 || true
  # Modul panel harus ada di WEB_DIR sebelum bot dijalankan (cli_shim & kawan-kawan).
  [[ -f "${WEB_DIR}/cli_shim.py" ]] || web_write_files || { err "Paket panel belum siap; jalankan: vpsnat web-setup"; return 1; }
  [[ -z "$token" ]] && read -rp "Token bot (dari @BotFather): " token
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { err "Format token tidak valid."; return 1; }
  [[ -z "$admin" ]] && read -rp "Chat ID admin (pisah koma): " admin
  admin="${admin// /}"; [[ "$admin" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || { err "Chat ID harus angka (pisah koma)."; return 1; }

  info "Cek token Telegram..."
  me=$(curl -fsS -m 15 "https://api.telegram.org/bot${token}/getMe") || { err "Tidak dapat menghubungi Telegram."; return 1; }
  jq -e '.ok==true' <<<"$me" >/dev/null 2>&1 || { err "Token ditolak Telegram."; return 1; }
  conf_set TG_TOKEN "$token"; conf_set TG_ADMIN "$admin"

  apt-get install -y python3 python3-venv python3-pip >/dev/null 2>&1 || { err "Gagal menyiapkan Python."; return 1; }
  python3 -m venv "${BOT_DIR}/venv" 2>/dev/null || { mkdir -p "$BOT_DIR"; python3 -m venv "${BOT_DIR}/venv" || { err "Gagal buat venv."; return 1; }; }
  "${BOT_DIR}/venv/bin/pip" install -q --upgrade pip || true
  "${BOT_DIR}/venv/bin/pip" install -q 'python-telegram-bot>=20,<23' || { err "Gagal install python-telegram-bot."; return 1; }
  bot_write_files || return 1
  bot_write_unit
  systemctl enable --now "${BOT_SERVICE}.service" >/dev/null 2>&1 || { err "Bot gagal start."; return 1; }
  sleep 2
  if systemctl is-active --quiet "${BOT_SERVICE}.service"; then ok "Bot aktif: @$(jq -r '.result.username' <<<"$me")"; else err "Bot gagal start. Cek journalctl -u ${BOT_SERVICE} -n 50"; return 1; fi
}

bot_ctl() {
  need_root
  case "${1:-}" in
    on) systemctl enable --now "${BOT_SERVICE}.service" && ok "Bot ON.";;
    off) systemctl disable --now "${BOT_SERVICE}.service" && ok "Bot OFF.";;
    restart) systemctl restart "${BOT_SERVICE}.service" && ok "Bot restart.";;
    status) systemctl status "${BOT_SERVICE}.service" --no-pager -n 20;;
    logs) journalctl -u "${BOT_SERVICE}" -n 80 --no-pager;;
    remove) systemctl disable --now "${BOT_SERVICE}.service" 2>/dev/null || true; rm -f "/etc/systemd/system/${BOT_SERVICE}.service"; rm -rf "$BOT_DIR"; systemctl daemon-reload; ok "Bot dihapus.";;
    *) echo "Pakai: vpsnat bot [on|off|restart|status|logs|remove]"; return 1;;
  esac
}
