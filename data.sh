#!/usr/bin/env bash

snap_menu() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local act="${2:-}" s="${3:-}" c
  if [[ -z "$act" ]]; then
    [[ "$NONINTERACTIVE" == "1" ]] && { err "Aksi snapshot wajib: create|list|restore|delete"; return 1; }
    echo "1) Buat snapshot  2) List  3) Restore  4) Hapus"; read -rp "Pilih: " c
    case "$c" in 1) act=create;;2) act=list;;3) act=restore;;4) act=delete;;*) return 0;;esac
  fi
  case "$act" in
    create) [[ -z "$s" && "$NONINTERACTIVE" != "1" ]] && read -rp "Nama snapshot [snap-$(date +%m%d-%H%M)]: " s; s=${s:-snap-$(date +%m%d-%H%M)}; preflight_vps_copy "$n" "snapshot ${n}" && lxc snapshot "$n" "$s" && ok "Snapshot ${s} dibuat.";;
    list) lxc info "$n" | sed -n '/^Snapshots:/,$p';;
    restore) [[ -z "$s" ]] && { lxc info "$n" | sed -n '/^Snapshots:/,$p'; read -rp "Nama snapshot: " s; }; confirm "Restore ${n} ke ${s}?" && lxc restore "$n" "$s" && ok "Restore selesai.";;
    delete) [[ -z "$s" ]] && { lxc info "$n" | sed -n '/^Snapshots:/,$p'; read -rp "Nama snapshot: " s; }; lxc delete "${n}/${s}" && ok "Snapshot dihapus.";;
    *) err "Aksi tidak dikenal: ${act}"; return 1;;
  esac
}

vps_backup() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local dir="/var/backups/vpsnat" f; mkdir -p "$dir"; f="${dir}/${n}-$(date +%Y%m%d-%H%M%S).tar.gz"
  preflight_backup "$n" "$dir" || return 1
  info "Export ${n} → ${f}"; lxc export "$n" "$f" --optimized-storage 2>/dev/null || lxc export "$n" "$f" || { err "Backup gagal."; return 1; }
  ok "Backup: ${f} ($(du -h "$f" | cut -f1))"
}

vps_restore() {
  need_root
  local dir="/var/backups/vpsnat" f="${1:-}"
  if [[ -z "$f" ]]; then ls -1 "$dir" 2>/dev/null || { err "Belum ada backup."; return 1; }; read -rp "Nama file backup: " f; fi
  [[ "$f" == */* || "$f" == *..* ]] && { err "Nama file tidak valid."; return 1; }
  [[ -f "${dir}/${f}" ]] || { err "File tidak ada."; return 1; }
  preflight_restore "${dir}/${f}" || return 1
  lxc import "${dir}/${f}" && ok "Import selesai. Jalankan Sync DB untuk mendaftarkan."
}

vps_limits_io() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local rd wr net
  if [[ "$NONINTERACTIVE" == "1" ]]; then rd="${RD:-}"; wr="${WR:-}"; net="${NET:-}"; else read -rp "Limit disk read (mis. 50MB, kosong=unlimited): " rd; read -rp "Limit disk write (mis. 50MB, kosong=unlimited): " wr; read -rp "Limit network ingress/egress (legacy LXD, kosong=unlimited): " net; fi
  lxc config device set "$n" root limits.read "${rd}" 2>/dev/null || lxc config device override "$n" root limits.read="${rd}"
  lxc config device set "$n" root limits.write "${wr}" 2>/dev/null || lxc config device override "$n" root limits.write="${wr}"
  lxc config device set "$n" eth0 limits.ingress "${net}" 2>/dev/null || lxc config device override "$n" eth0 limits.ingress="${net}"
  lxc config device set "$n" eth0 limits.egress "${net}" 2>/dev/null || lxc config device override "$n" eth0 limits.egress="${net}"
  ok "Limit I/O legacy LXD diterapkan. Untuk bandwidth dedicated, gunakan: vpsnat bandwidth ${n} set <quota_gb> <mbps>"
}

vps_stats() {
  local n; n=$(pick_vps "${1:-}") || return 1
  lxc info "$n" | sed -n '/^Resources:/,/^Snapshots:/p'; echo
  echo "--- Bandwidth ---"; bandwidth_status "$n"; echo
  lxc exec "$n" -- sh -c 'echo "--- uptime ---"; uptime; echo "--- df ---"; df -h /; echo "--- mem ---"; free -m 2>/dev/null' 2>/dev/null
}

host_stats() {
  echo -e "${W}=== Host ===${N}"; echo "Public IP : $(pub_ip)"; echo "Iface     : $(detect_iface)"; echo "CPU       : $(nproc) core"; echo -e "HW Virt   : $(hw_virt_label)"
  free -m | awk 'NR==2{printf "RAM       : %s / %s MB\n",$3,$2}'; df -h / | awk 'NR==2{printf "Disk      : %s / %s (%s)\n",$3,$2,$5}'; echo
  lxc list -c ns4mDlt --format table 2>/dev/null; echo; lxc storage info "$POOL" 2>/dev/null | sed -n '1,15p'
}

_vps_sync_locked() {
  need_root
  local name ip ssh cpu ram disk vt
  while IFS= read -r name; do
    [[ -z "$name" || -n "$(db_get "$name")" ]] && continue
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]] || { err "Nama guest orphan tidak aman untuk sync; dilewati."; continue; }
    warn "Container '${name}' tidak ada di DB, menambahkan..."
    ip=$(lxc list "$name" -c 4 --format csv | awk '{print $1}'); ssh=$(next_ssh_port); cpu=$(lxc config get "$name" limits.cpu); cpu=${cpu:-1}; ram=$(lxc config get "$name" limits.memory | tr -dc '0-9'); ram=${ram:-1024}; disk=$(lxc config device get "$name" root size | tr -dc '0-9'); disk=${disk:-10}; vt=$(lxc info "$name" | awk '/^Type:/{print $2}'); [[ "$vt" == "virtual-machine" ]] && vt="vm" || vt="container"
    [[ "$ssh" =~ ^[0-9]{1,5}$ ]] && (( 10#$ssh >= 1 && 10#$ssh <= 65535 )) || { err "SSH port tidak valid untuk ${name}; dilewati dan perlu diperiksa manual."; continue; }
    [[ "$ip" =~ ^${NET_PREFIX//./\.}\.([2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|250)$ ]] || { err "IP guest tidak valid untuk ${name}; guest tidak disinkronkan."; continue; }
    if cut -d'|' -f2 "$DB_FILE" | grep -Fqx "$ip"; then
      err "IP ${ip} guest ${name} sudah dipakai record DB lain; sync dibatalkan untuk mencegah bentrok tenant."
      continue
    fi
    lxc config set "$name" boot.autostart false >/dev/null 2>&1 || warn "Tidak dapat menonaktifkan autostart ${name}; status sync-pending harus diperiksa manual."
    if ! lxc stop "$name" --timeout 20 >/dev/null 2>&1 && ! lxc stop "$name" --force >/dev/null 2>&1; then
      warn "Guest ${name} gagal dihentikan; akan tetap di-karantina di DB, tetapi periksa LXD segera."
    fi
    db_add "$name" "$ip" "$ssh" "$cpu" "$ram" "$disk" "tcp:${ssh}:22" "unknown" "$(date +%F)" "$vt" 0 "-" 1 shared 0 0 || { err "Gagal menyimpan record sync untuk ${name}; guest dihentikan dan autostart dinonaktifkan."; continue; }
    db_set_field "$name" 25 "sync-pending" || { err "Gagal memberi status karantina sync untuk ${name}; periksa DB manual."; continue; }
  done < <(lxc list -c n --format csv 2>/dev/null)
  apply_all_rules || { err "Sync database selesai tetapi firewall gagal direkonsiliasi; record tetap dipertahankan."; return 1; }
  bandwidth_sync_all || { err "Sync bandwidth gagal."; return 1; }
  ok "Sync selesai. Container yang baru ditemukan tetap suspended (sync-pending); periksa lalu aktifkan dengan vpsnat unsuspend NAMA."
}

vps_sync() { with_alloc_lock _vps_sync_locked "$@"; }

set_public_ip() {
  local cur ip="${1:-}"; cur=$(pub_ip); [[ -z "$ip" ]] && { read -rp "Public IP [${cur}]: " ip; ip=${ip:-$cur}; }
  ipv4_valid "$ip" || { err "Format IPv4 tidak valid."; return 1; }
  conf_set PUBLIC_IP "$ip"; ok "Public IP: ${ip}"
}

cmd_check() {
  echo -e "${W}=== Cek Virtualisasi ===${N}"; echo "Environment : $(systemd-detect-virt 2>/dev/null || echo unknown)"; echo "CPU flag    : $(grep -m1 -oE 'vmx|svm' /proc/cpuinfo || echo tidak-ada)"; echo "/dev/kvm    : $([[ -e /dev/kvm ]] && echo ada || echo tidak-ada)"; echo -e "Status      : $(hw_virt_label)"; vm_supported && echo "Mode        : container + VM (KVM)" || echo "Mode        : container-only (tanpa VT-x/AMD-V)"
}
