#!/usr/bin/env bash

show_help() {
  cat <<EOF2
vpsnat v${VERSION}

Pemakaian: vpsnat [command] [argumen]

Instalasi
  install                         install LXD/NAT/firewall/monitor
  upgrade                         upgrade code + migrasi DB
  uninstall                       hapus seluruh VPSNAT + VPS (destruktif)
  check                           cek virtualisasi

VPS
  create [nama]                   buat VPS
  list                            daftar VPS
  info <nama>                     detail VPS + bandwidth
  start|stop|restart <nama>
  console <nama>                  shell guest
  exec <nama> <cmd>               command guest
  delete <nama>
  resize <nama>                   ubah CPU/RAM/Disk
  passwd <nama>
  reinstall <nama> [image]
  clone <nama> [baru]
  set-type <nama> shared|dedicated

Bandwidth
  bandwidth <nama> [show|set|reset|limit]
    set:    bandwidth <nama> set <quota_gb> <mbps>
    reset:  reset pemakaian kuota
    limit:  ubah speed tanpa mengubah quota
  resource-check                  sampling shared VPS + quota
  monitor [on|off|restart|status|logs]
  settings [show|set]             konfigurasi threshold/interval/default bandwidth

Port
  port-add <nama> <tcp|udp|both> <jumlah>
  port-range <nama> <tcp|udp|both> <jumlah>   alias port-add
  port-del <nama> <port-publik>
  port-list <nama>

Expired
  renew <nama> <durasi>            30d, 2w, 1m, 12h
  set-expire <nama> <durasi/tanggal/never>
  expiring [hari]
  suspend|unsuspend <nama>
  set-owner <nama> <label>
  grace <hari>
  expire-check

Data
  snapshot <nama> [create|list|restore|delete] [nama-snapshot]
  backup <nama>
  restore-backup [file]
  limits <nama>                    legacy LXD I/O/network limits
  stats <nama>
  host
  sync
  restore                         reapply firewall
  publicip [ip]

Multi-Node Dashboard
  nodes                            dashboard gabungan semua node (via relay tunnel)
  nodes list                       daftar node terdaftar
  nodes add <label> <ip-tunnel> [ssh-port] [ssh-user]
  nodes del <label>
  nodes label <label>              set label node ini (tampil di dashboard node lain)

Bot Telegram
  bot-setup [token] [chat_id]
  bot [on|off|restart|status|logs|remove]

Relay / Universal Network
  relay init
  relay peer-add <node-ip> <node-wireguard-public-key>
  relay attach <relay-ip:port> <relay-wireguard-public-key> [node-ip]
  relay detach
  relay status
  relay on|off|restart|logs

Non-interaktif:
  VPSNAT_NONINTERACTIVE=1 VPSNAT_YES=1 <command>
EOF2
}

monitor_ctl() {
  need_root
  case "${1:-status}" in
    on) systemctl enable --now "${MONITOR_SERVICE}.service" && ok "Monitor ON.";;
    off) systemctl disable --now "${MONITOR_SERVICE}.service" && ok "Monitor OFF.";;
    restart) systemctl restart "${MONITOR_SERVICE}.service" && ok "Monitor restart.";;
    status) systemctl status "${MONITOR_SERVICE}.service" --no-pager -n 20;;
    logs) journalctl -u "${MONITOR_SERVICE}" -n 80 --no-pager;;
    *) echo "Pakai: vpsnat monitor [on|off|restart|status|logs]"; return 1;;
  esac
}

menu() {
  while true; do
    clear
    echo -e "${W}${B}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${W}${B}║                 VPSNAT v${VERSION}                 ║${N}"
    echo -e "${W}${B}╚══════════════════════════════════════════════════╝${N}"
    local count monitor_state; count=$(grep -c . "$DB_FILE" 2>/dev/null || echo 0); monitor_state="OFF"; systemctl is-active --quiet "${MONITOR_SERVICE}.service" 2>/dev/null && monitor_state="${G}ON${N}"
    echo -e " Public IP: $(pub_ip)   VPS: ${count}   Monitor: ${monitor_state}"
    echo -e " VT-x/AMD-V: $(hw_virt_label)"
    echo
    echo -e " ${W}VPS${N}"; echo "  1 Create       2 List        3 Info        4 Start"
    echo "  5 Stop        6 Restart     7 Console    8 Delete"
    echo "  9 Resize     10 Password   11 Reinstall 12 Clone"
    echo " 13 Set type"
    echo -e " ${W}Network${N}"; echo " 14 Add port   15 Delete port 16 List port  17 Bandwidth"
    echo " 18 Legacy limits"
    echo -e " ${W}Expired${N}"; echo " 27 Renew      28 Set expire  29 Expiring   30 Suspend"
    echo " 31 Unsuspend 32 Set owner    33 Grace      34 Expire check"
    echo -e " ${W}Data/System${N}"; echo " 19 Snapshot   20 Backup      21 Restore    22 Stats"
    echo " 23 Host       24 Sync        25 Public IP 26 Reapply FW"
    echo " 35 Monitor    36 Bot setup   37 Bot control 38 Virtualization"
    echo " 39 Multi-node dashboard"
    echo "  0 Exit"
    echo
    local c a
    read -rp " Pilih: " c; echo
    case "$c" in
      1) vps_create;; 2) vps_list;; 3) vps_info;; 4) vps_start;; 5) vps_stop;; 6) vps_restart;; 7) vps_console;; 8) vps_delete;; 9) vps_resize;; 10) vps_passwd;; 11) vps_reinstall;; 12) vps_clone;; 13) vps_set_plan;;
      14) port_add;; 15) port_del;; 16) port_list;; 17) vps_bandwidth;; 18) vps_limits_io;;
      19) snap_menu;; 20) vps_backup;; 21) vps_restore;; 22) vps_stats;; 23) host_stats;; 24) vps_sync;; 25) set_public_ip;; 26) apply_all_rules && ok "Rule diterapkan.";;
      27) vps_renew;; 28) vps_setexpire;; 29) vps_expiring;; 30) vps_suspend;; 31) vps_unsuspend;; 32) vps_setowner;; 33) set_grace;; 34) vps_expire_check && ok "Expire check selesai.";;
      35) read -rp "on/off/restart/status/logs: " a; monitor_ctl "$a";; 36) bot_setup;; 37) read -rp "on/off/restart/status/logs/remove: " a; bot_ctl "$a";; 38) cmd_check;; 39) nodes_dashboard;; 0) exit 0;; *) warn "Pilihan tidak valid.";;
    esac
    pause
  done
}

main() {
  export PATH="$PATH:/snap/bin"
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install) cmd_install "$@";; upgrade) cmd_upgrade "$@";; uninstall) cmd_uninstall "$@";; check) cmd_check;; help|-h|--help) show_help;; relay) relay_dispatch "$@";;
    *)
      need_root; command -v lxc >/dev/null 2>&1 || [[ -x /snap/bin/lxc ]] || die "LXD belum terinstall. Jalankan: ./vpsnat install"; db_init; ensure_net
      case "$cmd" in
        "") menu;; create) vps_create "$@";; list|ls) vps_list;; info) vps_info "$@";; start) vps_start "$@";; stop) vps_stop "$@";; restart) vps_restart "$@";; console|shell) vps_console "$@";; exec) vps_exec "$@";; delete|rm) vps_delete "$@";; resize) vps_resize "$@";; passwd) vps_passwd "$@";; reinstall) vps_reinstall "$@";; clone) vps_clone "$@";; set-type) vps_set_plan "$@";;
        renew) vps_renew "$@";; set-expire) vps_setexpire "$@";; expiring) vps_expiring "$@";; suspend) vps_suspend "$@";; unsuspend) vps_unsuspend "$@";; set-owner) vps_setowner "$@";; grace) set_grace "$@";; expire-check) vps_expire_check;;
        port-add) port_add "$@";; port-range) port_range_add "$@";; port-del) port_del "$@";; port-list) port_list "$@";; bandwidth|bw) vps_bandwidth "$@";; resource-check) resource_check;; monitor) monitor_ctl "$@";; monitor-loop) monitor_loop;; settings|config) settings_cmd "$@";;
        snapshot|snap) snap_menu "$@";; backup) vps_backup "$@";; restore-backup) vps_restore "$@";; limits) vps_limits_io "$@";; stats) vps_stats "$@";; host) host_stats;; host-brief) host_summary_brief;; sync) vps_sync;; restore) apply_all_rules;; publicip) set_public_ip "$@";; bot-setup) bot_setup "$@";; bot) bot_ctl "$@";; nodes) nodes_dispatch "$@";; *) show_help; return 1;;
      esac
      ;;
  esac
}
