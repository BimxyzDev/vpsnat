#!/usr/bin/env bash

web_write_files() {
  mkdir -p "$WEB_DIR"
  [[ -f "${VPSNAT_APP_DIR}/web.py" && -f "${VPSNAT_APP_DIR}/web.html" ]] || { err "web.py / web.html tidak ditemukan di ${VPSNAT_APP_DIR}."; return 1; }
  install -m 700 "${VPSNAT_APP_DIR}/web.py" "${WEB_DIR}/web.py"
  install -m 600 "${VPSNAT_APP_DIR}/web.html" "${WEB_DIR}/web.html"
}

web_write_unit() {
  cat > "/etc/systemd/system/${WEB_SERVICE}.service" <<EOF2
[Unit]
Description=VPSNAT Web Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${WEB_DIR}/web.py
Restart=always
RestartSec=5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

web_hash_pass() {
  printf '%s' "$1" | python3 "${WEB_DIR}/web.py" hashpw
}

web_set_admin_pass() {
  local pass="$1" hash
  [[ ${#pass} -ge 8 && ${#pass} -le 64 ]] || { err "Password admin 8-64 karakter."; return 1; }
  hash=$(web_hash_pass "$pass") && [[ "$hash" == scrypt:* ]] || { err "Gagal membuat hash password."; return 1; }
  conf_set WEB_ADMIN_HASH "$hash"
}

web_gen_key() {
  local key
  key=$(openssl rand -hex 24) || return 1
  conf_set WEB_API_KEY "$key"
  echo "$key"
}

web_setup() {
  need_root
  local port="${1:-}" user="${2:-}" pass="${3:-}" bind key generated=0
  command -v python3 >/dev/null 2>&1 || apt-get install -y python3 >/dev/null 2>&1 || { err "python3 tidak tersedia."; return 1; }

  local cur_port; cur_port="$(conf_get WEB_PORT)"; cur_port="${cur_port:-$WEB_PORT_DEFAULT}"
  [[ -z "$port" ]] && read -rp "Port web [${cur_port}]: " port
  port="${port:-$cur_port}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) || { err "Port harus 1024-65535."; return 1; }
  if (( port >= PORT_MIN && port <= PORT_MAX )); then err "Port ${port} bentrok dengan range port VPS (${PORT_MIN}-${PORT_MAX})."; return 1; fi
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && ! systemctl is-active --quiet "${WEB_SERVICE}.service"; then
    err "Port ${port} sudah dipakai proses lain."; return 1
  fi

  [[ -z "$user" ]] && { read -rp "Username admin [admin]: " user; user="${user:-admin}"; }
  [[ "$user" =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || { err "Username 3-32 karakter (huruf, angka, _ . -)."; return 1; }
  if [[ -z "$pass" ]]; then
    read -rsp "Password admin (kosong=random): " pass; echo
    [[ -z "$pass" ]] && { pass=$(gen_pass); generated=1; }
  fi

  bind="$(conf_get WEB_BIND)"; bind="${bind:-0.0.0.0}"
  web_write_files || return 1
  conf_set WEB_PORT "$port"
  conf_set WEB_BIND "$bind"
  conf_set WEB_ADMIN_USER "$user"
  [[ -n "$(conf_get WEB_TRUST_PROXY)" ]] || conf_set WEB_TRUST_PROXY 0
  [[ -n "$(conf_get WEB_SESSION_HOURS)" ]] || conf_set WEB_SESSION_HOURS 12
  web_set_admin_pass "$pass" || return 1
  key=$(web_gen_key) || { err "Gagal membuat API key."; return 1; }
  web_write_unit
  systemctl enable --now "${WEB_SERVICE}.service" >/dev/null 2>&1 || true
  systemctl restart "${WEB_SERVICE}.service" >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet "${WEB_SERVICE}.service"; then
    ok "Web panel aktif di http://$(pub_ip):${port}"
    info "Admin   : ${user} / $([[ $generated == 1 ]] && echo "$pass" || echo "(password yang diinput)")"
    info "API key : ${key}"
    warn "Tanpa HTTPS, password lewat jaringan tidak terenkripsi. Pasang di belakang Cloudflare Tunnel / reverse proxy TLS, lalu set WEB_TRUST_PROXY=1 di ${CONF_FILE} dan jalankan: vpsnat web restart"
    warn "Jika memakai ufw: ufw allow ${port}/tcp"
  else
    err "Web gagal start. Cek: journalctl -u ${WEB_SERVICE} -n 50"
    return 1
  fi
}

web_ctl() {
  need_root
  case "${1:-}" in
    on) systemctl enable --now "${WEB_SERVICE}.service" && ok "Web ON.";;
    off) systemctl disable --now "${WEB_SERVICE}.service" && ok "Web OFF.";;
    restart) systemctl restart "${WEB_SERVICE}.service" && ok "Web restart.";;
    status) systemctl status "${WEB_SERVICE}.service" --no-pager -n 20;;
    logs) journalctl -u "${WEB_SERVICE}" -n 80 --no-pager;;
    key)
      [[ -f "${WEB_DIR}/web.py" ]] || { err "Web belum di-setup. Jalankan: vpsnat web-setup"; return 1; }
      local k; k=$(web_gen_key) || return 1
      ok "API key baru: ${k}"
      ;;
    passwd)
      [[ -f "${WEB_DIR}/web.py" ]] || { err "Web belum di-setup. Jalankan: vpsnat web-setup"; return 1; }
      local p="${2:-}"
      [[ -z "$p" ]] && { read -rsp "Password admin baru: " p; echo; }
      web_set_admin_pass "$p" && ok "Password admin diganti."
      ;;
    remove)
      systemctl disable --now "${WEB_SERVICE}.service" 2>/dev/null || true
      rm -f "/etc/systemd/system/${WEB_SERVICE}.service"
      rm -rf "$WEB_DIR"
      local k
      for k in WEB_PORT WEB_BIND WEB_ADMIN_USER WEB_ADMIN_HASH WEB_API_KEY WEB_TRUST_PROXY WEB_SESSION_HOURS; do
        [[ -f "$CONF_FILE" ]] && sed -i "/^${k}=/d" "$CONF_FILE"
      done
      systemctl daemon-reload
      ok "Web dihapus."
      ;;
    *) echo "Pakai: vpsnat web [on|off|restart|status|logs|key|passwd|remove]"; return 1;;
  esac
}
