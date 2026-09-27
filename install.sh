#!/usr/bin/env bash

install_runtime_tree() {
  local src="${VPSNAT_APP_DIR}" stage
  [[ -d "$src" ]] || die "Source aplikasi tidak ditemukan: $src"
  if [[ "$(realpath "$src")" == "$(realpath "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
    chmod +x "$src/vpsnat"
    return 0
  fi
  stage="${INSTALL_DIR}.new"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -a "$src/." "$stage/"
  find "$stage" -type f -name '*.sh' -exec chmod 755 {} +
  chmod 755 "$stage/vpsnat"
  rm -rf "$INSTALL_DIR"
  mv "$stage" "$INSTALL_DIR"
  cat > "$BIN_PATH" <<EOF2
#!/usr/bin/env bash
export VPSNAT_APP_DIR="${INSTALL_DIR}"
exec "${INSTALL_DIR}/vpsnat" "\$@"
EOF2
  chmod 755 "$BIN_PATH"
}

write_systemd_services() {
  cat > /etc/systemd/system/vpsnat-restore.service <<EOF2
[Unit]
Description=VPSNAT firewall restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH} restore
RemainAfterExit=yes
EOF2

  cat > "/etc/systemd/system/${EXPIRE_TIMER}.service" <<EOF2
[Unit]
Description=VPSNAT expiry check

[Service]
Type=oneshot
ExecStart=${BIN_PATH} expire-check
EOF2
  cat > "/etc/systemd/system/${EXPIRE_TIMER}.timer" <<EOF2
[Unit]
Description=VPSNAT expiry check hourly

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  cat > "/etc/systemd/system/${MONITOR_SERVICE}.service" <<EOF2
[Unit]
Description=VPSNAT resource and bandwidth monitor
After=network-online.target snap.lxd.daemon.service ${EXPIRE_TIMER}.timer
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} monitor-loop
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

set_default_config() {
  [[ -n "$(conf_get GRACE_DAYS)" ]] || conf_set GRACE_DAYS "$GRACE_DAYS_DEFAULT"
  [[ -n "$(conf_get SHARED_SUSPEND_MINUTES)" ]] || conf_set SHARED_SUSPEND_MINUTES "$SHARED_SUSPEND_MINUTES_DEFAULT"
  [[ -n "$(conf_get RESOURCE_SAMPLE_SECONDS)" ]] || conf_set RESOURCE_SAMPLE_SECONDS "$RESOURCE_SAMPLE_SECONDS_DEFAULT"
  [[ -n "$(conf_get SHARED_RESOURCE_THRESHOLD)" ]] || conf_set SHARED_RESOURCE_THRESHOLD "$RESOURCE_THRESHOLD_DEFAULT"
  [[ -n "$(conf_get BANDWIDTH_DEFAULT_RATE_MBIT)" ]] || conf_set BANDWIDTH_DEFAULT_RATE_MBIT "$BANDWIDTH_DEFAULT_RATE_MBIT"
  [[ -n "$(conf_get BANDWIDTH_DEFAULT_QUOTA_GB)" ]] || conf_set BANDWIDTH_DEFAULT_QUOTA_GB "$BANDWIDTH_DEFAULT_QUOTA_GB"
  [[ -n "$(conf_get NETWORK_MODE)" ]] || conf_set NETWORK_MODE "$NETWORK_MODE_DEFAULT"
}

cmd_install() {
  need_root
  ensure_runtime_dirs
  db_init
  check_virt_env
  install_deps
  enable_forward
  init_lxd
  fw_setup
  set_public_ip
  set_default_config
  install_runtime_tree
  write_systemd_services
  systemctl enable --now vpsnat-restore.service >/dev/null 2>&1 || true
  systemctl enable --now "${EXPIRE_TIMER}.timer" >/dev/null 2>&1 || true
  systemctl enable --now "${MONITOR_SERVICE}.service" >/dev/null 2>&1 || true
  bandwidth_sync_all
  apply_all_rules
  ok "Install v${VERSION} selesai."
  info "CLI: vpsnat | Monitor: ${MONITOR_SERVICE} | Expire: ${EXPIRE_TIMER}.timer"
  info "Bot opsional: vpsnat bot-setup"
}

cmd_upgrade() {
  need_root
  ensure_runtime_dirs
  db_init
  set_default_config
  install_runtime_tree
  write_systemd_services
  systemctl enable --now "${EXPIRE_TIMER}.timer" >/dev/null 2>&1 || true
  systemctl enable --now "${MONITOR_SERVICE}.service" >/dev/null 2>&1 || true
  if [[ -f "${BOT_DIR}/bot.py" ]]; then bot_write_files || true; bot_write_unit; systemctl restart "${BOT_SERVICE}.service" 2>/dev/null || true; fi
  bandwidth_sync_all
  apply_all_rules
  ok "Upgrade ke v${VERSION} selesai. DB lama dimigrasikan ke schema ${DB_FIELDS} field."
}

cmd_uninstall() {
  need_root
  confirm "Hapus semua VPS, bridge, storage & konfigurasi VPSNAT? Ini destruktif." || return 0
  export PATH="$PATH:/snap/bin"
  local name
  while IFS= read -r name; do [[ -n "$name" ]] && lxc delete "$name" --force 2>/dev/null || true; done < <(lxc list -c n --format csv 2>/dev/null)
  iptables -t nat -F VPSNAT_PRE 2>/dev/null || true; iptables -t nat -F VPSNAT_POST 2>/dev/null || true; iptables -F VPSNAT_FWD 2>/dev/null || true
  lxc profile delete "$PROFILE" 2>/dev/null || true; lxc network delete "$BRIDGE" 2>/dev/null || true; lxc storage delete "$POOL" 2>/dev/null || true
  systemctl disable --now vpsnat-restore.service 2>/dev/null || true; systemctl disable --now "${EXPIRE_TIMER}.timer" 2>/dev/null || true; systemctl disable --now "${MONITOR_SERVICE}.service" 2>/dev/null || true; systemctl disable --now "${BOT_SERVICE}.service" 2>/dev/null || true
  rm -f /etc/systemd/system/vpsnat-restore.service "/etc/systemd/system/${EXPIRE_TIMER}.service" "/etc/systemd/system/${EXPIRE_TIMER}.timer" "/etc/systemd/system/${MONITOR_SERVICE}.service" "/etc/systemd/system/${BOT_SERVICE}.service" "$BIN_PATH"
  rm -rf "$INSTALL_DIR" "$BASE_DIR"
  systemctl daemon-reload
  ok "Uninstall selesai."
}
