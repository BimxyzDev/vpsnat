#!/usr/bin/env bash
# Installer DATA-PLANE (node) — padanan `pterodactyl/wings`.
#
# Yang dipasang di node:
#   * LXD (snap), storage pool, bridge lxdbr0, profil VPSNAT
#   * firewall NAT (chains VPSNAT_*), sysctl forwarding, hardening host
#   * node DB (/etc/vpsnat/vps.db): sumber kebenaran proses di node ini
#   * agent HTTP (vpsnat-node.service) di port 8788 — panel mengirim perintah ke sini
#   * monitor / expiry / restore (systemd)
#
# Node TIDAK menyimpan web panel dan tidak menyimpan data client (nama, kredensial
# client) sebagai sumber kebenaran — itu milik panel. Yang ada di node hanya
# metadata runtime yang diperlukan untuk menjalankan DNAT dan auto-suspend.

node_write_agent_unit() {
  cat > "/etc/systemd/system/${NODE_AGENT_SERVICE}.service" <<EOF2
[Unit]
Description=VPSNAT Node Agent (data-plane)
After=network-online.target snap.lxd.daemon.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/node/agent.py serve
Restart=always
RestartSec=3
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

node_set_defaults() {
  [[ -n "$(conf_get GRACE_DAYS)" ]] || conf_set GRACE_DAYS "$GRACE_DAYS_DEFAULT"
  [[ -n "$(conf_get SHARED_SUSPEND_MINUTES)" ]] || conf_set SHARED_SUSPEND_MINUTES "$SHARED_SUSPEND_MINUTES_DEFAULT"
  [[ -n "$(conf_get RESOURCE_SAMPLE_SECONDS)" ]] || conf_set RESOURCE_SAMPLE_SECONDS "$RESOURCE_SAMPLE_SECONDS_DEFAULT"
  [[ -n "$(conf_get SHARED_RESOURCE_THRESHOLD)" ]] || conf_set SHARED_RESOURCE_THRESHOLD "$RESOURCE_THRESHOLD_DEFAULT"
  [[ -n "$(conf_get BANDWIDTH_DEFAULT_RATE_MBIT)" ]] || conf_set BANDWIDTH_DEFAULT_RATE_MBIT "$BANDWIDTH_DEFAULT_RATE_MBIT"
  [[ -n "$(conf_get BANDWIDTH_DEFAULT_QUOTA_GB)" ]] || conf_set BANDWIDTH_DEFAULT_QUOTA_GB "$BANDWIDTH_DEFAULT_QUOTA_GB"
  [[ -n "$(conf_get NETWORK_MODE)" ]] || conf_set NETWORK_MODE "$NETWORK_MODE_DEFAULT"
  [[ -n "$(conf_get NODE_AGENT_PORT)" ]] || conf_set NODE_AGENT_PORT "$NODE_AGENT_PORT_DEFAULT"
  [[ -n "$(conf_get NODE_AGENT_BIND)" ]] || conf_set NODE_AGENT_BIND "0.0.0.0"
  return 0
}

cmd_install_node() {
  need_root
  role_set node >/dev/null
  ensure_runtime_dirs
  check_virt_env
  install_deps
  enable_forward
  init_lxd
  fw_setup
  set_public_ip
  node_set_defaults
  install_runtime_tree || { err "Gagal memasang runtime node."; return 1; }
  db_init || { err "Gagal menyiapkan node DB."; return 1; }
  write_systemd_services
  node_write_agent_unit
  # Identitas node (nama + token) otomatis.
  python3 "${INSTALL_DIR}/node/agent.py" identity --name "$(hostname | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-' | cut -c1-30)" >/dev/null 2>&1 || true
  local tok; tok=$(python3 "${INSTALL_DIR}/node/agent.py" token 2>/dev/null || true)
  systemctl enable --now vpsnat-restore.service >/dev/null 2>&1 || true
  systemctl enable --now "${EXPIRE_TIMER}.timer" >/dev/null 2>&1 || true
  systemctl enable --now "${MONITOR_SERVICE}.service" >/dev/null 2>&1 || true
  systemctl enable --now "${NODE_AGENT_SERVICE}.service" >/dev/null 2>&1 || true
  bandwidth_sync_all
  apply_all_rules
  ok "Install NODE v${VERSION} selesai."
  echo
  info "Token node: ${tok:-(belum dibuat — jalankan: vpsnat node init)}"
  info "Daftarkan node ini dari PANEL:"
  echo "   vpsnat node add $(python3 "${INSTALL_DIR}/node/agent.py" identity 2>/dev/null | sed -n 's/.*"name": "\([^"]*\)".*/\1/p' | head -1) http://$(pub_ip):${NODE_AGENT_PORT_DEFAULT} $(pub_ip) 20000-24999"
  echo "   (tempel token di atas dengan opsi --token <token>)"
  echo
  warn "Buka port ${NODE_AGENT_PORT_DEFAULT}/tcp HANYA untuk IP panel di firewall provider/VPS."
  info "Cek status: vpsnat node status | vpsnat node-agent status"
}

node_doctor() {
  need_root
  echo -e "${W}=== VPSNAT Node ===${N}"
  echo "Peran host   : $(role_label)"
  echo "Versi        : ${VERSION}"
  echo "Public IP    : $(pub_ip)"
  echo "Iface        : $(detect_iface)"
  echo "Node DB      : ${DB_FILE} ($(db_rows_count "$DB_FILE") instance)"
  echo "Agent        : $(systemctl is-active "${NODE_AGENT_SERVICE}.service" 2>/dev/null || echo tidak-aktif) (port $(cfg_int NODE_AGENT_PORT "$NODE_AGENT_PORT_DEFAULT"))"
  echo "Monitor      : $(systemctl is-active "${MONITOR_SERVICE}.service" 2>/dev/null || echo tidak-aktif)"
  echo "Expiry timer : $(systemctl is-active "${EXPIRE_TIMER}.timer" 2>/dev/null || echo tidak-aktif)"
  echo
  host_stats
}
