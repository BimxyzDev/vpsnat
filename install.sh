#!/usr/bin/env bash

install_runtime_tree() {
  local src="${VPSNAT_APP_DIR}" stage
  [[ -d "$src" ]] || die "Source aplikasi tidak ditemukan: $src"
  # Self-heal: git kadang menyimpan file ini dengan mode 644 (mis. commit pertama lewat
  # GitHub web UI, atau clone dari mirror/zip). Selalu pastikan executable di source SEBELUM
  # dicopy, supaya instalasi jalan walau dipanggil lewat `bash vpsnat install` tanpa execute-bit.
  find "$src" -maxdepth 1 -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
  chmod 755 "$src/vpsnat" 2>/dev/null || true
  if [[ "$(realpath "$src")" == "$(realpath "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
    return 0
  fi
  stage="${INSTALL_DIR}.new"
  previous="${INSTALL_DIR}.previous"
  bin_tmp="${BIN_PATH}.new"
  rm -rf "$stage" || { err "Gagal membersihkan staging directory."; return 1; }
  mkdir -p "$stage" || { err "Gagal membuat staging directory."; return 1; }
  cp -a "$src/." "$stage/" || { rm -rf "$stage"; err "Gagal menyalin source ke staging."; return 1; }
  find "$stage" -type f -name '*.sh' -exec chmod 755 {} + || { rm -rf "$stage"; err "Gagal mengatur permission script."; return 1; }
  chmod 755 "$stage/vpsnat" || { rm -rf "$stage"; err "Gagal mengatur permission CLI."; return 1; }
  rm -rf "$previous" || { rm -rf "$stage"; err "Gagal membersihkan backup runtime lama."; return 1; }
  if [[ -d "$INSTALL_DIR" ]]; then
    mv "$INSTALL_DIR" "$previous" || { rm -rf "$stage"; err "Gagal memindahkan runtime lama."; return 1; }
  fi
  if ! mv "$stage" "$INSTALL_DIR"; then
    [[ ! -e "$INSTALL_DIR" && -d "$previous" ]] && mv "$previous" "$INSTALL_DIR" || true
    rm -rf "$stage"
    err "Gagal memasang runtime baru; pemulihan runtime lama telah dicoba."
    return 1
  fi
  cat > "$bin_tmp" <<EOF2
#!/usr/bin/env bash
export VPSNAT_APP_DIR="${INSTALL_DIR}"
exec "${INSTALL_DIR}/vpsnat" "\$@"
EOF2
  chmod 755 "$bin_tmp" || { rm -f "$bin_tmp"; err "Gagal mengatur permission CLI wrapper."; return 1; }
  mv -f "$bin_tmp" "$BIN_PATH" || { rm -f "$bin_tmp"; err "Gagal memasang CLI wrapper."; return 1; }
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
  info "Bot opsional: vpsnat bot-setup | Web panel opsional: vpsnat web-setup"
}

_upgrade_restore_previous_runtime() {
  local previous="${INSTALL_DIR}.previous" failed="${INSTALL_DIR}.failed"
  [[ -d "$previous" ]] || { err "Runtime sebelumnya tidak tersedia untuk rollback (${previous})."; return 1; }
  rm -rf "$failed" || return 1
  [[ ! -d "$INSTALL_DIR" ]] || mv "$INSTALL_DIR" "$failed" || return 1
  mv "$previous" "$INSTALL_DIR" || {
    [[ ! -e "$INSTALL_DIR" && -d "$failed" ]] && mv "$failed" "$INSTALL_DIR" || true
    err "Gagal memulihkan runtime sebelumnya."; return 1
  }
  cat > "${BIN_PATH}.rollback" <<EOF2
#!/usr/bin/env bash
export VPSNAT_APP_DIR="${INSTALL_DIR}"
exec "${INSTALL_DIR}/vpsnat" "\$@"
EOF2
  chmod 755 "${BIN_PATH}.rollback" && mv -f "${BIN_PATH}.rollback" "$BIN_PATH" || { err "Runtime kembali tetapi wrapper CLI gagal dipulihkan."; return 1; }
  rm -rf "$failed"
  VPSNAT_APP_DIR="$INSTALL_DIR" write_systemd_services >/dev/null 2>&1 || true
  [[ ! -f "${BOT_DIR}/bot.py" ]] || { VPSNAT_APP_DIR="$INSTALL_DIR" bot_write_files >/dev/null 2>&1 || true; VPSNAT_APP_DIR="$INSTALL_DIR" bot_write_unit >/dev/null 2>&1 || true; }
  [[ ! -f "${WEB_DIR}/web.py" ]] || { VPSNAT_APP_DIR="$INSTALL_DIR" web_write_files >/dev/null 2>&1 || true; VPSNAT_APP_DIR="$INSTALL_DIR" web_write_unit >/dev/null 2>&1 || true; }
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ ! -f "${BOT_DIR}/bot.py" ]] || systemctl restart "${BOT_SERVICE}.service" >/dev/null 2>&1 || true
  [[ ! -f "${WEB_DIR}/web.py" ]] || systemctl restart "${WEB_SERVICE}.service" >/dev/null 2>&1 || true
  warn "Runtime sebelumnya dipulihkan. Periksa log dan layanan untuk penyebab upgrade gagal."
}

cmd_upgrade() {
  need_root
  local rollback_on_fail=0 source_real install_real
  source_real=$(realpath "$VPSNAT_APP_DIR" 2>/dev/null || printf '%s' "$VPSNAT_APP_DIR")
  install_real=$(realpath "$INSTALL_DIR" 2>/dev/null || printf '%s' "$INSTALL_DIR")
  # No-op if invoked from the installed tree; do not restore a stale .previous.
  [[ -d "$INSTALL_DIR" && "$source_real" != "$install_real" ]] && rollback_on_fail=1
  ensure_runtime_dirs || { err "Gagal menyiapkan direktori runtime."; return 1; }
  # Backup DB SEBELUM migrasi pertama oleh kode baru. Dipakai untuk memulihkan DB bila migrasi merusaknya.
  local db_backup="" rows_before=0
  if [[ -s "$DB_FILE" ]]; then
    rows_before=$(db_rows_count "$DB_FILE")
    db_backup=$(db_backup_snapshot pre-upgrade "v${VERSION}") || { err "Backup DB sebelum upgrade gagal; upgrade dibatalkan."; return 1; }
    [[ -n "$db_backup" ]] && info "Backup DB: ${db_backup}"
  fi
  db_init || { err "Migrasi database gagal; upgrade dibatalkan (backup DB: ${db_backup:--})."; return 1; }
  if [[ -n "$db_backup" ]] && { [[ "$(db_rows_count "$DB_FILE")" != "$rows_before" ]] || ! db_verify_file "$DB_FILE"; }; then
    err "Verifikasi DB pasca-migrasi gagal (record sebelum=${rows_before}, sesudah=$(db_rows_count "$DB_FILE")); memulihkan dari ${db_backup}."
    with_lock cp -p "$db_backup" "$DB_FILE" || err "GAGAL memulihkan DB otomatis; salin manual ${db_backup} -> ${DB_FILE}."
    return 1
  fi
  set_default_config || { err "Gagal memeriksa konfigurasi default."; return 1; }
  install_runtime_tree || { err "Pemasangan runtime gagal; upgrade dibatalkan."; return 1; }
  write_systemd_services || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal menulis unit systemd."; return 1; }
  systemctl enable --now "${EXPIRE_TIMER}.timer" >/dev/null 2>&1 || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal mengaktifkan expiry timer."; return 1; }
  systemctl enable --now "${MONITOR_SERVICE}.service" >/dev/null 2>&1 || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal mengaktifkan monitor."; return 1; }
  if [[ -f "${BOT_DIR}/bot.py" ]]; then
    bot_write_files || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal menyalin file bot."; return 1; }
    bot_write_unit || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal menulis service bot."; return 1; }
    systemctl restart "${BOT_SERVICE}.service" || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal restart bot service."; return 1; }
  fi
  if [[ -f "${WEB_DIR}/web.py" ]]; then
    web_write_files || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal menyalin file web."; return 1; }
    web_write_unit || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal menulis service web."; return 1; }
    systemctl restart "${WEB_SERVICE}.service" || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Gagal restart web service."; return 1; }
  fi
  bandwidth_sync_all || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Sync bandwidth gagal."; return 1; }
  apply_all_rules || { (( rollback_on_fail )) && _upgrade_restore_previous_runtime || true; err "Rekonsiliasi firewall gagal; periksa log sebelum menyatakan upgrade selesai."; return 1; }
  ok "Upgrade ke v${VERSION} selesai. DB lama dimigrasikan ke schema ${DB_FIELDS} field."
  [[ -n "$db_backup" ]] && info "Backup DB pra-upgrade: ${db_backup}"
  info "Hardening VPS lama (limit proses + anti-spoofing NIC): vpsnat harden --check, lalu vpsnat harden all"
}

cmd_uninstall() {
  need_root
  confirm "Hapus semua VPS, bridge, storage & konfigurasi VPSNAT? Ini destruktif." || return 0
  export PATH="$PATH:/snap/bin"
  local name
  while IFS= read -r name; do [[ -n "$name" ]] && lxc delete "$name" --force 2>/dev/null || true; done < <(lxc list -c n --format csv 2>/dev/null)
  iptables -t nat -F VPSNAT_PRE 2>/dev/null || true; iptables -t nat -F VPSNAT_POST 2>/dev/null || true; iptables -F VPSNAT_FWD 2>/dev/null || true
  lxc profile delete "$PROFILE" 2>/dev/null || true; lxc network delete "$BRIDGE" 2>/dev/null || true; lxc storage delete "$POOL" 2>/dev/null || true
  systemctl disable --now vpsnat-restore.service 2>/dev/null || true; systemctl disable --now "${EXPIRE_TIMER}.timer" 2>/dev/null || true; systemctl disable --now "${MONITOR_SERVICE}.service" 2>/dev/null || true; systemctl disable --now "${BOT_SERVICE}.service" 2>/dev/null || true; systemctl disable --now "${WEB_SERVICE}.service" 2>/dev/null || true
  web_nginx_remove
  rm -f /etc/systemd/system/vpsnat-restore.service "/etc/systemd/system/${EXPIRE_TIMER}.service" "/etc/systemd/system/${EXPIRE_TIMER}.timer" "/etc/systemd/system/${MONITOR_SERVICE}.service" "/etc/systemd/system/${BOT_SERVICE}.service" "/etc/systemd/system/${WEB_SERVICE}.service" "$BIN_PATH"
  rm -rf "$INSTALL_DIR" "$BASE_DIR"
  systemctl daemon-reload
  ok "Uninstall selesai."
}
