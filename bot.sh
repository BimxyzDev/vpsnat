#!/usr/bin/env bash

bot_write_files() {
  mkdir -p "$BOT_DIR"
  [[ -f "${VPSNAT_APP_DIR}/bot.py" ]] || { err "bot.py tidak ditemukan di ${VPSNAT_APP_DIR}."; return 1; }
  install -m 700 "${VPSNAT_APP_DIR}/bot.py" "${BOT_DIR}/bot.py"
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
  local token="${1:-}" admin="${2:-}" me
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
