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
    info "Pakai domain + HTTPS otomatis: vpsnat web-domain panel.contoh.com"
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
      web_nginx_remove
      for k in WEB_PORT WEB_BIND WEB_ADMIN_USER WEB_ADMIN_HASH WEB_API_KEY WEB_TRUST_PROXY WEB_SESSION_HOURS WEB_DOMAIN WEB_IP_HEADER WEB_BRAND WEB_LOGO_URL; do
        [[ -f "$CONF_FILE" ]] && sed -i "/^${k}=/d" "$CONF_FILE"
      done
      systemctl daemon-reload
      ok "Web dihapus."
      ;;
    domain) web_domain "${@:2}";;
    *) echo "Pakai: vpsnat web [on|off|restart|status|logs|key|passwd|domain|remove]"; return 1;;
  esac
}

web_domain_valid() {
  [[ ${#1} -le 253 && "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

web_nginx_remove() {
  local changed=0
  [[ -L "$WEB_NGINX_LINK" || -f "$WEB_NGINX_LINK" ]] && { rm -f "$WEB_NGINX_LINK"; changed=1; }
  [[ -f "$WEB_NGINX_SITE" ]] && { rm -f "$WEB_NGINX_SITE"; changed=1; }
  if (( changed )) && command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || true
  fi
}

web_domain_check_dns() {
  local d="$1" want got
  want=$(pub_ip)
  got=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -z "$got" ]]; then warn "DNS ${d} belum resolve. Buat A record ke ${want}."; return 1; fi
  if [[ "$got" != "$want" ]]; then warn "DNS ${d} mengarah ke ${got}, bukan ${want} (normal jika memakai proxy Cloudflare)."; return 1; fi
  ok "DNS ${d} → ${got}"
}

web_domain_apply() {
  local domain="$1" ip_header="$2"
  conf_set WEB_DOMAIN "$domain"
  conf_set WEB_BIND 127.0.0.1
  conf_set WEB_TRUST_PROXY 1
  conf_set WEB_IP_HEADER "$ip_header"
  systemctl restart "${WEB_SERVICE}.service" >/dev/null 2>&1 || true
}

web_domain_nginx() {
  local domain="$1" email="${2:-}" port
  port="$(conf_get WEB_PORT)"; port="${port:-$WEB_PORT_DEFAULT}"
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
    info "Install nginx + certbot..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y nginx certbot python3-certbot-nginx >/dev/null 2>&1 || { err "Gagal install nginx/certbot."; return 1; }
  fi
  cat > "$WEB_NGINX_SITE" <<EOF2
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};
  client_max_body_size 128k;

  location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header CF-Connecting-IP "";
    proxy_read_timeout 120s;
  }
}
EOF2
  ln -sf "$WEB_NGINX_SITE" "$WEB_NGINX_LINK"
  nginx -t >/dev/null 2>&1 || { err "Konfigurasi nginx tidak valid:"; nginx -t; web_nginx_remove; return 1; }
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl reload nginx >/dev/null 2>&1 || { err "nginx gagal reload (port 80 dipakai proses lain?)."; return 1; }
  local -a args=(--nginx -d "$domain" --non-interactive --agree-tos --redirect)
  if [[ -n "$email" ]]; then args+=(-m "$email"); else args+=(--register-unsafely-without-email); fi
  info "Minta sertifikat Let's Encrypt untuk ${domain}..."
  if ! certbot "${args[@]}"; then
    err "certbot gagal. Pastikan A record ${domain} → $(pub_ip) dan port 80/443 terbuka. Setelah beres: vpsnat web-domain ${domain}"
    return 1
  fi
  web_domain_apply "$domain" "X-Forwarded-For"
  ok "Panel aktif di https://${domain}"
  info "Port ${port} sekarang hanya lokal (127.0.0.1). Buka firewall 80/443 (ufw allow 80,443/tcp)."
}

web_domain_tunnel() {
  local domain="$1" port
  port="$(conf_get WEB_PORT)"; port="${port:-$WEB_PORT_DEFAULT}"
  web_domain_apply "$domain" "CF-Connecting-IP"
  ok "Mode tunnel: panel hanya mendengar di 127.0.0.1:${port}."
  info "Cloudflare Tunnel, tambahkan ingress:"
  echo "  - hostname: ${domain}"
  echo "    service: http://127.0.0.1:${port}"
  info "Atau: cloudflared tunnel route dns <nama-tunnel> ${domain}"
}

web_domain_status() {
  local d; d="$(conf_get WEB_DOMAIN)"
  if [[ -z "$d" ]]; then
    info "Domain belum diatur. Pakai: vpsnat web-domain panel.contoh.com"
  else
    info "Domain : ${d}"
    info "Bind   : $(conf_get WEB_BIND):$(conf_get WEB_PORT)"
    [[ -f "$WEB_NGINX_SITE" ]] && info "Mode   : nginx + Let's Encrypt" || info "Mode   : tunnel / proxy eksternal"
  fi
}

web_domain() {
  need_root
  [[ -f "${WEB_DIR}/web.py" ]] || { err "Web belum di-setup. Jalankan: vpsnat web-setup"; return 1; }
  local domain="${1:-}" mode="${2:-nginx}" email="${3:-}"
  case "$domain" in
    ""|status) web_domain_status; return 0;;
    remove|off)
      web_nginx_remove
      conf_set WEB_BIND 0.0.0.0
      conf_set WEB_TRUST_PROXY 0
      sed -i '/^WEB_DOMAIN=/d;/^WEB_IP_HEADER=/d' "$CONF_FILE"
      systemctl restart "${WEB_SERVICE}.service" >/dev/null 2>&1 || true
      ok "Domain dilepas. Panel kembali di http://$(pub_ip):$(conf_get WEB_PORT)"
      return 0;;
  esac
  domain="${domain,,}"
  web_domain_valid "$domain" || { err "Domain tidak valid: ${domain}"; return 1; }
  case "$mode" in
    nginx)
      web_domain_check_dns "$domain" || confirm "DNS belum cocok, lanjut tetap?" || return 1
      web_domain_nginx "$domain" "$email";;
    tunnel) web_domain_tunnel "$domain";;
    *) err "Mode: nginx | tunnel"; return 1;;
  esac
}
