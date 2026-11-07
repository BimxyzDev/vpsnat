#!/usr/bin/env bash

show_help() {
  cat <<EOF2
vpsnat v${VERSION} — panel & node manager VPS (LXD + NAT), model panel/node.

Pemakaian: vpsnat [command] [argumen]

PASANG (pilih salah satu peran)
  install-panel                   control-plane: DB client, web panel, bot, worker
  install-node                    data-plane: LXD, NAT, agent (VPS client jalan di sini)
  install                         deteksi peran dari instalasi/lingkungan yang ada
  setup                           perintah pertama: pilih peran lalu pasang
  upgrade                         pasang ulang runtime lokal + migrasi DB
  update [--check|--force]        ambil source terbaru dari GitHub, tes, lalu upgrade
  uninstall [panel|node|all]      hapus komponen (destruktif)
  check                           cek virtualisasi
  doctor [panel|node]             ringkasan kesehatan + diagnosa
  role [panel|node|both]          tampilkan / ubah peran host ini

NODE registry (dijalankan di PANEL)
  node init                       siapkan identitas node (dijalankan di NODE)
  node attach <token>             terima token dari panel (dijalankan di NODE)
  node add <nama> <url> <wan-ip> [port-min-max]
                                  daftarkan node ke panel (token dicetak)
  node list | show <nama> [--token] | ping <nama> | token <nama> [--rotate]
  node del <nama>
  node-agent [on|off|restart|status|logs]   agent di NODE
  node status                     status node ini

SERVER (dijalankan di NODE; panel mengirim perintah lewat agent)
  create [nama]                   buat VPS client
  list                            daftar VPS client di node ini
  info <nama>                     detail + SSH + password
  start|stop|restart <nama>
  console <nama>                  shell guest
  exec <nama> <cmd>               command guest
  delete <nama>
  resize <nama>
  passwd <nama>
  reinstall <nama> [image]
  clone <nama> [baru]
  set-type <nama> shared|dedicated
  suspend|unsuspend <nama>

PANEL
  panel status                    ringkasan panel
  panel worker [once|on|off]      worker job (kirim job ke node)
  panel import [--node N] [--dry-run]   impor VPS yang sudah ada ke panel DB
  sync                            sinkronkan status semua server dari node
  jobs [id]                       daftar job / detail satu job
  servers [--node N]              daftar server versi panel DB
  alloc [node] [--free]           daftar alokasi port milik panel
  web-setup [port] [user] [pass]  pasang admin web panel
  web [on|off|restart|status|logs|key|passwd|domain|remove]
  web-domain <domain> [nginx|tunnel] [email]
  bot-setup [token] [chat_id]
  bot [on|off|restart|status|logs|remove]

Bandwidth & resource
  bandwidth <nama> [show|set|reset|limit]
  resource-check                  sampling shared VPS + quota
  monitor [on|off|restart|status|logs]
  settings [show|set]

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
  restore                         reapply firewall (+ MSS clamp relay)
  db-backup [create|list]         backup DB node (otomatis juga sebelum upgrade)
  audit [tail [N]|search <kata>]  audit trail JSONL (siapa mengubah apa, kapan)
  harden [nama|all] [--check]     limit proses + anti-spoofing NIC; --check = laporan saja
  publicip [ip]

Multi-Node Dashboard (relay)
  nodes                            dashboard gabungan semua node (via relay tunnel)
  nodes list | add <label> <ip-tunnel> [ssh-port] [ssh-user] | del <label>
  nodes label <label>              set label node ini (tampil di dashboard node lain)

Relay / Universal Network
  relay init                                   (di relay)
  relay node-add <label> [min-max]             (di relay) daftarkan node, cetak token join
  relay join <token>                           (di node) tempel token dari node-add
  relay node-list | node-del <label>           (di relay)
  relay peer-add <node-ip> <node-public-key> [min-max] [label]   (manual, di relay)
  relay attach <relay-ip:port> <relay-public-key> [node-ip]      (manual, di node)
  relay slice <min-max|off>                    (di node) batasi alokasi port VPS
  relay detach | relay status | relay on|off|restart|logs

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

jobs_cmd() {
  panel_ready || return 1
  PYTHONPATH="${VPSNAT_APP_DIR}/panel" VPSNAT_PANEL_DB="$PANEL_DB" python3 - "$VPSNAT_APP_DIR" "${1:-}" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "panel"))
import db
jid = sys.argv[2] if len(sys.argv) > 2 else ""
if jid:
    job = db.job_get(jid)
    if not job:
        print("[x] job tidak ditemukan"); raise SystemExit(1)
    for k, v in job.items():
        print(f"{k:<10}: {v}")
else:
    rows = db.jobs_recent(30)
    print("=== Job (30 terbaru) ===")
    if not rows:
        print("(belum ada job)")
    for r in rows:
        ts = time.strftime("%m-%d %H:%M", time.localtime(r["started"]))
        print(f"{r['id']}  {ts}  {r['kind']:<10} {r['target']:<16} {r['status']:<12} node_job={r['node_job'] or '-'}")
PYEOF
}

menu() {
  local role; role=$(vpsnat_role)
  while true; do
    clear
    echo -e "${W}${B}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${W}${B}║                 VPSNAT v${VERSION}                 ║${N}"
    echo -e "${W}${B}╚══════════════════════════════════════════════════╝${N}"
    echo -e " Peran: $(role_label)"
    if role_is_node; then
      local count monitor_state; count=$(grep -c . "$DB_FILE" 2>/dev/null || echo 0)
      monitor_state="OFF"; systemctl is-active --quiet "${MONITOR_SERVICE}.service" 2>/dev/null && monitor_state="${G}ON${N}"
      echo -e " Public IP: $(pub_ip)   Instance: ${count}   Monitor: ${monitor_state}"
      echo -e " VT-x/AMD-V: $(hw_virt_label)"
    fi
    if role_is_panel; then echo -e " Panel DB: ${PANEL_DB}"; fi
    echo
    if role_is_panel; then
      echo -e " ${W}Panel${N}"; echo "  1 Web setup    2 Web control  3 Web domain   4 Bot setup"
      echo "  5 Bot control  6 Node add     7 Node list    8 Node ping"
      echo "  9 Node del    10 Sync        11 Jobs        12 Panel status"
    fi
    if role_is_node; then
      echo -e " ${W}Node${N}"; echo " 20 Install node 21 Node init  22 Node status  23 Harden"
    fi
    echo -e " ${W}VPS${N}"; echo " 30 Create      31 List        32 Info        33 Start"
    echo " 34 Stop        35 Restart     36 Delete      37 Resize"
    echo " 38 Password    39 Reinstall   40 Bandwidth   41 Port list"
    echo -e " ${W}Sistem${N}"; echo " 50 Host        51 Doctor      52 Settings    53 Audit"
    echo "  0 Exit"
    echo
    local c a
    read -rp " Pilih: " c; echo
    case "$c" in
      1) web_setup;; 2) read -rp "on/off/restart/status/logs/key/passwd/remove: " a; web_ctl "$a";; 3) read -rp "Domain (kosong=status): " a; web_domain "$a";; 4) bot_setup;;
      5) read -rp "on/off/restart/status/logs/remove: " a; bot_ctl "$a";; 6) node_add;; 7) node_list;; 8) read -rp "Nama node: " a; node_ping "$a";;
      9) node_del;; 10) panel_sync_cmd;; 11) jobs_cmd;; 12) panel_doctor;;
      20) cmd_install_node;; 21) node_init;; 22) node_status;; 23) vps_harden;;
      30) vps_create;; 31) vps_list;; 32) vps_info;; 33) vps_start;; 34) vps_stop;; 35) vps_restart;; 36) vps_delete;; 37) vps_resize;; 38) vps_passwd;; 39) vps_reinstall;; 40) vps_bandwidth;; 41) port_list;;
      50) host_stats;; 51) cmd_doctor;; 52) settings_cmd show;; 53) audit_cmd tail 20;;
      0) exit 0;; *) warn "Pilihan tidak valid.";;
    esac
    pause
  done
}

# `vpsnat restore`: firewall + MSS clamp relay (host relay/node lama otomatis ter-patch).
cmd_restore() {
  apply_all_rules || return 1
  relay_mss_boot || true
}

cmd_check() {
  echo -e "${W}=== Cek Virtualisasi ===${N}"; echo "Environment : $(systemd-detect-virt 2>/dev/null || echo unknown)"; echo "CPU flag    : $(grep -m1 -oE 'vmx|svm' /proc/cpuinfo || echo tidak-ada)"; echo "/dev/kvm    : $([[ -e /dev/kvm ]] && echo ada || echo tidak-ada)"; echo -e "Status      : $(hw_virt_label)"; vm_supported && echo "Mode        : container + VM (KVM)" || echo "Mode        : container-only (tanpa VT-x/AMD-V)"
}

# Setup awal: pilih peran lalu jalankan installer yang sesuai.
cmd_setup() {
  need_root
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      role="$(vpsnat_role)"
      [[ "$role" == "unknown" ]] && { err "Tentukan peran: VPSNAT_ROLE=panel|node|both vpsnat setup"; return 1; }
    else
      echo "Pilih peran host ini:"
      echo "  1) panel  — control-plane: simpan data client + IP/port SSH, jalankan web panel (VPS kecil)"
      echo "  2) node   — data-plane: jalankan seluruh VPS client (LXD + NAT), seperti wings"
      echo "  3) both   — satu host menjalankan keduanya (mode lama)"
      local c; read -rp "Pilihan [1/2/3]: " c
      case "${c:-1}" in 1) role=panel;; 2) role=node;; 3) role=both;; *) err "Pilihan tidak valid."; return 1;; esac
    fi
  fi
  case "$role" in
    panel) cmd_install_panel ;;
    node) cmd_install_node ;;
    both)
      cmd_install_node
      cmd_install_panel || warn "Installer panel menemukan masalah; periksa output di atas."
      ;;
    *) err "Peran harus panel, node, atau both."; return 1 ;;
  esac
}

cmd_doctor() {
  case "${1:-$(vpsnat_role)}" in
    panel) panel_doctor ;;
    node) node_doctor ;;
    both) panel_doctor; echo; node_doctor ;;
    *) echo "Peran belum ditentukan. Jalankan: vpsnat setup"; return 1 ;;
  esac
}

# `vpsnat node ...` — sub-perintah panel (registry) dan node (identitas).
nodes_cmd() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    init) node_init "$@";;
    attach) node_attach "$@";;
    status) node_status "$@";;
    add) node_add "$@";;
    list|ls) node_list "$@";;
    show) node_show "$@";;
    ping) node_ping "$@";;
    token) node_token "$@";;
    del|rm|remove) node_del "$@";;
    *) echo "Pakai: vpsnat node [init|attach|status|add|list|show|ping|token|del]"; return 1;;
  esac
}

main() {
  export PATH="$PATH:/snap/bin"
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install) cmd_setup "$@";;
    install-panel) cmd_install_panel "$@";;
    install-node) cmd_install_node "$@";;
    setup) cmd_setup "$@";;
    update) vpsnat_update "$@";;
    upgrade) cmd_upgrade "$@";;
    uninstall) cmd_uninstall "$@";;
    check) cmd_check;;
    doctor) cmd_doctor "$@";;
    role) [[ -n "${1:-}" ]] && role_set "$1" || { echo "Peran host ini: $(role_label)"; echo "File: ${ROLE_FILE}"; };;
    help|-h|--help) show_help;;
    relay) relay_dispatch "$@";;
    node) nodes_cmd "$@";;
    node-agent) node_ctl "$@";;
    panel) panel_ctl "$@";;
    panel-worker) panel_worker_cmd "$@";;
    sync) panel_sync_cmd "$@";;
    jobs) jobs_cmd "$@";;
    *)
      need_root
      db_init 2>/dev/null || true
      if role_is_node; then
        command -v lxc >/dev/null 2>&1 || [[ -x /snap/bin/lxc ]] || \
          die "LXD belum terinstall di node ini. Jalankan: vpsnat install-node"
        ensure_net 2>/dev/null || true
      fi
      case "$cmd" in
        "") menu;;
        create) require_node_role || return 1; vps_create "$@";;
        list|ls) require_node_role || return 1; vps_list;;
        info) require_node_role || return 1; vps_info "$@";;
        start) require_node_role || return 1; vps_start "$@";;
        stop) require_node_role || return 1; vps_stop "$@";;
        restart) require_node_role || return 1; vps_restart "$@";;
        console|shell) require_node_role || return 1; vps_console "$@";;
        exec) require_node_role || return 1; vps_exec "$@";;
        delete|rm) require_node_role || return 1; vps_delete "$@";;
        resize) require_node_role || return 1; vps_resize "$@";;
        passwd) require_node_role || return 1; vps_passwd "$@";;
        reinstall) require_node_role || return 1; vps_reinstall "$@";;
        clone) require_node_role || return 1; vps_clone "$@";;
        set-type) require_node_role || return 1; vps_set_plan "$@";;
        renew) require_node_role || return 1; vps_renew "$@";;
        set-expire) require_node_role || return 1; vps_setexpire "$@";;
        expiring) require_node_role || return 1; vps_expiring "$@";;
        suspend) require_node_role || return 1; vps_suspend "$@";;
        unsuspend) require_node_role || return 1; vps_unsuspend "$@";;
        set-owner) require_node_role || return 1; vps_setowner "$@";;
        grace) set_grace "$@";;
        expire-check) require_node_role || return 1; vps_expire_check;;
        port-add) require_node_role || return 1; port_add "$@";;
        port-range) require_node_role || return 1; port_range_add "$@";;
        port-del) require_node_role || return 1; port_del "$@";;
        port-list) require_node_role || return 1; port_list "$@";;
        alloc) nodes_alloc_list "$@";;
        servers) panel_servers_list "$@";;
        bandwidth|bw) require_node_role || return 1; vps_bandwidth "$@";;
        resource-check) require_node_role || return 1; resource_check;;
        monitor) monitor_ctl "$@";;
        monitor-loop) require_node_role || return 1; monitor_loop;;
        settings|config) settings_cmd "$@";;
        audit) audit_cmd "$@";;
        snapshot|snap) require_node_role || return 1; snap_menu "$@";;
        backup) require_node_role || return 1; vps_backup "$@";;
        restore-backup) require_node_role || return 1; vps_restore "$@";;
        limits) require_node_role || return 1; vps_limits_io "$@";;
        stats) require_node_role || return 1; vps_stats "$@";;
        host) host_stats;;
        host-brief) host_summary_brief;;
        restore) cmd_restore;;
        harden) require_node_role || return 1; vps_harden "$@";;
        db-backup) db_backup_cmd "$@";;
        publicip) set_public_ip "$@";;
        bot-setup) bot_setup "$@";;
        bot) bot_ctl "$@";;
        web-setup) web_setup "$@";;
        web) web_ctl "$@";;
        web-domain) web_domain "$@";;
        nodes) nodes_dispatch "$@";;
        *) show_help; return 1;;
      esac
      ;;
  esac
}
