#!/usr/bin/env bash
# Installer CONTROL-PLANE (panel) — padanan `pterodactyl/panel`.
#
# Yang dipasang di panel:
#   * panel DB  (/etc/vpsnat/panel.db) : data client, kredensial, IP + port SSH
#   * web panel (/etc/vpsnat/web)      : UI + REST API
#   * bot Telegram (opsional)
#   * worker job (vpsnat-panel-worker) : mengirim job ke node + rekonsiliasi
#   * nginx + TLS (opsional, lewat vpsnat web-domain)
#
# Panel TIDAK memasang LXD dan tidak menjalankan VPS client, sehingga bisa
# memakai VPS kecil (2 GB RAM sudah cukup untuk ratusan client).

panel_write_worker_unit() {
  cat > "/etc/systemd/system/vpsnat-panel-worker.service" <<EOF2
[Unit]
Description=VPSNAT panel job worker (dispatch ke node)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH} panel-worker
Nice=5
EOF2

  cat > "/etc/systemd/system/vpsnat-panel-worker.timer" <<EOF2
[Unit]
Description=Jalankan VPSNAT panel job worker berkala

[Timer]
OnBootSec=1min
OnUnitActiveSec=20s
AccuracySec=5s
Persistent=false

[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload
}

panel_install_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y python3 >/dev/null 2>&1 || { err "python3 tidak bisa dipasang."; return 1; }
}

# Salin seluruh paket runtime (lib/, panel/, node/, bin/) ke INSTALL_DIR.
panel_write_files() {
  need_root
  install_runtime_tree || return 1
  mkdir -p "$WEB_DIR"
  install -m 700 "${VPSNAT_APP_DIR}/panel/app.py" "${WEB_DIR}/app.py" 2>/dev/null || true
  return 0
}

panel_set_defaults() {
  [[ -n "$(conf_get GRACE_DAYS)" ]] || conf_set GRACE_DAYS "$GRACE_DAYS_DEFAULT"
  [[ -n "$(conf_get WEB_PORT)" ]] || conf_set WEB_PORT "$PANEL_PORT_DEFAULT"
  [[ -n "$(conf_get WEB_BIND)" ]] || conf_set WEB_BIND "0.0.0.0"
  [[ -n "$(conf_get WEB_SESSION_HOURS)" ]] || conf_set WEB_SESSION_HOURS 12
  [[ -n "$(conf_get WEB_TRUST_PROXY)" ]] || conf_set WEB_TRUST_PROXY 0
}

cmd_install_panel() {
  need_root
  role_set panel >/dev/null
  ensure_runtime_dirs
  panel_install_python || return 1
  install_deps_panel || return 1
  panel_db_init || return 1
  panel_set_defaults
  install_runtime_tree || { err "Gagal memasang runtime panel."; return 1; }
  panel_write_worker_unit || { err "Gagal menulis unit worker."; return 1; }
  write_systemd_services
  systemctl enable --now vpsnat-panel-worker.timer >/dev/null 2>&1 || warn "Timer worker gagal diaktifkan; jalankan: systemctl enable --now vpsnat-panel-worker.timer"

  ok "Install PANEL v${VERSION} selesai."
  echo
  info "Langkah berikutnya:"
  echo "   1) Pasang admin web panel : sudo vpsnat web-setup"
  echo "   2) (opsional) Domain+HTTPS : sudo vpsnat web-domain panel.contoh.com"
  echo "   3) Daftarkan NODE         : sudo vpsnat node add <nama> <url-agent> <wan-ip> [port-min-max]"
  echo
  info "Cek status: vpsnat panel status   |   daftar node: vpsnat node list"
}

install_deps_panel() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl openssl jq util-linux python3 ca-certificates >/dev/null 2>&1 \
    || { err "Gagal memasang dependensi panel."; return 1; }
  return 0
}

# --- bot & web: keduanya hidup di panel -----------------------------------
panel_setup_flow() {
  need_root
  require_panel_role || return 1
  panel_db_init || return 1
  ok "Panel DB siap: ${PANEL_DB}"
}

panel_doctor() {
  need_root
  echo -e "${W}=== VPSNAT Panel ===${N}"
  echo "Peran host   : $(role_label)"
  echo "Versi        : ${VERSION}"
  echo "Panel DB     : ${PANEL_DB} $( [[ -s "$PANEL_DB" ]] && echo "(ada)" || echo "(belum ada)")"
  echo "Web panel    : $(systemctl is-active "${WEB_SERVICE}.service" 2>/dev/null || echo tidak-aktif)"
  echo "Bot          : $(systemctl is-active "${BOT_SERVICE}.service" 2>/dev/null || echo tidak-aktif)"
  echo "Worker job   : $(systemctl is-active vpsnat-panel-worker.timer 2>/dev/null || echo tidak-aktif)"
  echo
  if [[ -s "$PANEL_DB" ]]; then
    panel_py server-list 2>/dev/null | head -20 || true
    echo
    panel_py node-list 2>/dev/null || true
  else
    warn "Panel DB belum dibuat. Jalankan: vpsnat install-panel"
  fi
}

# Impor VPS yang sudah ada ke panel DB (upgrade dari v3 / node yang sudah berisi VPS).
panel_import_cmd() {
  need_root
  panel_ready || return 1
  PYTHONPATH="${VPSNAT_APP_DIR}/panel" VPSNAT_PANEL_DB="$PANEL_DB" \
    python3 "${VPSNAT_APP_DIR}/panel/import.py" "$@"
}

panel_ctl() {
  need_root
  case "${1:-status}" in
    status) panel_doctor ;;
    import) shift; panel_import_cmd "$@" ;;
    worker)
      case "${2:-once}" in
        once) BIN="${BIN_PATH}" "${BIN_PATH}" panel-worker ;;
        on) systemctl enable --now vpsnat-panel-worker.timer && ok "Worker ON." ;;
        off) systemctl disable --now vpsnat-panel-worker.timer && ok "Worker OFF." ;;
        *) err "Pakai: vpsnat panel worker [once|on|off]"; return 1 ;;
      esac ;;
    *) echo "Pakai: vpsnat panel [status|worker once|worker on|worker off]"; return 1 ;;
  esac
}

# Worker: jalankan job yang menunggu, rekonsiliasi, lalu sync status server.
# Dipanggil systemd timer (vpsnat-panel-worker.timer) atau manual: vpsnat panel worker once
panel_worker_cmd() {
  need_root
  panel_ready || return 1
  mkdir -p "$BASE_DIR" 2>/dev/null || true
  local lock="${BASE_DIR}/.panel-worker.lock"
  exec 6>"$lock" || return 1
  flock -n 6 || { info "Worker lain masih berjalan; dilewati."; exec 6>&-; return 0; }
  PYTHONPATH="${VPSNAT_APP_DIR}/panel" VPSNAT_PANEL_DB="$PANEL_DB" \
    python3 "${VPSNAT_APP_DIR}/panel/worker.py" >>"${BASE_DIR}/panel-worker.log" 2>&1 || true
  exec 6>&-
}

# Sinkronkan status semua server dari node.
panel_sync_cmd() {
  need_root
  panel_ready || return 1
  PYTHONPATH="${VPSNAT_APP_DIR}/panel" VPSNAT_PANEL_DB="$PANEL_DB" \
    python3 "${VPSNAT_APP_DIR}/panel/sync.py" "$@"
}
