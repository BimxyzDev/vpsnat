# ---------- CREATE ----------
# Interaktif: prompt. Non-interaktif (bot): env NAME IMG_KEY CPU RAM DISK PASS NPORTS NESTING VTYPE EXPIRE OWNER
pick_vps() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    [[ "$NONINTERACTIVE" == "1" ]] && { err "Nama VPS wajib diisi."; return 1; }
    vps_list >&2
    echo >&2
    read -rp "Nama VPS: " name
  fi
  [[ -z "$(db_get "$name")" ]] && { err "VPS '$name' tidak ditemukan."; return 1; }
  echo "$name"
}

vps_console() {
  local n; n=$(pick_vps "${1:-}") || return 1
  lxc exec "$n" -- bash 2>/dev/null || lxc exec "$n" -- sh
}

vps_exec() {
  local n cmd; n=$(pick_vps "${1:-}") || return 1
  shift || true
  cmd="$*"
  [[ -z "$cmd" ]] && read -rp "Command: " cmd
  lxc exec "$n" -- sh -c "$cmd"
}

# Hapus semua rule + LXC + DB untuk satu VPS (tanpa konfirmasi; dipakai delete & auto-expire)
_vps_delete_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  confirm "HAPUS ${n} beserta datanya?" || { info "Batal."; return 0; }
  _vps_purge_body "$n" || return 1
  ok "$n dihapus."
}

vps_delete() { with_alloc_lock _vps_delete_locked "$@"; }

_vps_passwd_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local pass
  if [[ "$NONINTERACTIVE" == "1" ]]; then pass="${PASS:-$(gen_pass)}"
  else read -rp "Password baru [random]: " pass; pass=${pass:-$(gen_pass)}; fi
  safe_password "$pass" || { err "Password harus 8-64 karakter (huruf, angka, dan simbol aman; tanpa spasi/newline)."; return 1; }
  printf 'root:%s\n' "$pass" | lxc exec "$n" -- chpasswd || { err "Gagal."; return 1; }
  if ! db_set_field "$n" 8 "$pass"; then
    local oldpass; oldpass=$(db_field "$n" 8)
    printf 'root:%s\n' "$oldpass" | lxc exec "$n" -- chpasswd >/dev/null 2>&1 || warn "Rollback password guest gagal; kredensial guest/DB mungkin berbeda. Periksa ${n} segera."
    err "Gagal menyimpan password ke DB; dicoba mengembalikan password guest ke nilai lama."; return 1
  fi
  ok "Password ${n}: ${pass}"
}

vps_passwd() { with_alloc_lock _vps_passwd_locked "$@"; }


# If provisioning fails and LXD cannot delete its half-created guest, keep its
# address and full port range reserved in a suspended DB record. Reusing either
# resource while an orphan guest exists can misroute traffic across tenants.
_vps_create_cleanup() {
  local n="$1" ip="$2" ssh="$3" cpu="$4" ram="$5" disk="$6" ports="$7" pass="$8" backend="$9" expires="${10}" owner="${11}" plan="${12}" quota="${13}" rate="${14}"
  if lxc delete "$n" --force >/dev/null 2>&1; then
    return 0
  fi
  if [[ -z "$(db_get "$n")" ]]; then
    db_add "$n" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$(date +%F)" "$backend" "$expires" "$owner" 1 "$plan" "$quota" "$rate" || {
      err "CRITICAL: guest orphan ${n} tidak bisa dihapus dan reservasi DB gagal dibuat. IP=${ip}, SSH=${ssh}, ports=${ports}. Periksa LXD/DB sekarang."
      return 1
    }
  fi
  db_set_fields "$n" "13=1" "25=provisioning-failed" || err "Gagal menandai ${n} sebagai provisioning-failed."
  apply_all_rules || warn "Gagal menghapus forwarding guest orphan ${n}; jalankan vpsnat restore setelah firewall pulih."
  err "Guest ${n} masih ada di LXD dan ditahan sebagai suspended/provisioning-failed. Reservasi IP/port dipertahankan. Hapus atau pulihkan secara manual setelah pemeriksaan."
  return 1
}

_vps_create_locked() {
  need_root
  local name img_key img cpu ram disk pass ssh_port ip extra vtype="container" vmflag="" nports requested_nports t expire owner exp_epoch persisted_ports
  local plan quota quota_bytes rate normalized plist portmap p
  name="${1:-${NAME:-}}"
  requested_nports="${2:-}"
  [[ -z "$name" ]] && ask name "Nama VPS (a-z0-9-): "
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Nama tidak valid."; return 1; }
  vps_exists "$name" && { err "VPS '$name' sudah ada."; return 1; }
  [[ -n "$(db_get "$name")" ]] && { err "Nama sudah ada di DB."; return 1; }

  plan="${PLAN_TYPE:-}" 
  if [[ -z "$plan" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then plan="shared"; else read -rp "Tipe layanan (1=shared, 2=dedicated) [1]: " t; [[ "${t:-1}" == "2" ]] && plan="dedicated" || plan="shared"; fi
  fi
  [[ "$plan" =~ ^(shared|dedicated)$ ]] || { err "Tipe layanan harus shared atau dedicated."; return 1; }

  if vm_supported; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then t="${VTYPE:-1}"; [[ "$t" == "vm" ]] && t=2; else read -rp "Backend (1=container, 2=VM KVM) [1]: " t; fi
    [[ "${t:-1}" == "2" ]] && { vtype="vm"; vmflag="--vm"; }
  else
    info "VT-x/AMD-V tidak tersedia → backend otomatis: container."
  fi

  if [[ "$NONINTERACTIVE" != "1" ]]; then echo "Image: ubuntu24 | ubuntu22 | ubuntu20 | debian12 | debian11 | alma9 | rocky9 | alpine"; fi
  IMG_KEY="${IMG_KEY:-}"; ask img_key "Image [ubuntu22]: " ""; [[ -z "$img_key" ]] && img_key="${IMG_KEY:-}"
  img=$(image_for "${img_key:-ubuntu22}")
  if [[ "$vtype" == "vm" && "$img" == images:alpine/* ]]; then warn "Alpine VM kurang stabil, pakai ubuntu22."; img="ubuntu:22.04"; fi

  cpu="${CPU:-}"; ask cpu "CPU core [1]: " 1
  ram="${RAM:-}"; ask ram "RAM MB [1024]: " 1024
  disk="${DISK:-}"; ask disk "Disk GB [10]: " 10
  [[ "$cpu" =~ ^[0-9]{1,3}$ && "$ram" =~ ^[0-9]{1,7}$ && "$disk" =~ ^[0-9]{1,5}$ ]] || { err "CPU/RAM/Disk harus integer dengan panjang valid."; return 1; }
  cpu=$((10#$cpu)); ram=$((10#$ram)); disk=$((10#$disk))
  (( cpu >= 1 && cpu <= 128 && ram >= 128 && ram <= 1048576 && disk >= 1 && disk <= 10000 )) || { err "Resource di luar batas: CPU 1-128, RAM 128-1048576 MB, disk 1-10000 GB."; return 1; }

  if [[ "$NONINTERACTIVE" == "1" ]]; then pass="${PASS:-$(gen_pass)}"; else read -rp "Root password [random]: " pass; pass=${pass:-$(gen_pass)}; fi
  safe_password "$pass" || { err "Password harus 8-64 karakter (huruf, angka, dan simbol aman; tanpa spasi/newline)."; return 1; }

  if [[ -n "$requested_nports" ]]; then
    nports="$requested_nports"
  elif [[ "$NONINTERACTIVE" == "1" ]]; then
    nports="${NPORTS:-3}"
  else
    read -rp "Jumlah port total (${VPS_PORTS_MIN}-${VPS_PORTS_MAX}) [3]: " nports
    nports=${nports:-3}
  fi
  [[ "$nports" =~ ^[0-9]{1,2}$ ]] || { err "Jumlah port harus ${VPS_PORTS_MIN}-${VPS_PORTS_MAX}."; return 1; }
  nports=$((10#$nports))
  (( nports >= VPS_PORTS_MIN && nports <= VPS_PORTS_MAX )) || { err "Jumlah port harus ${VPS_PORTS_MIN}-${VPS_PORTS_MAX}."; return 1; }
  info "Jumlah port diminta: ${nports} (termasuk port SSH)."

  if [[ "$vtype" == "container" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then extra="${NESTING:-y}"; else read -rp "Aktifkan nesting (Docker di dalam VPS)? [Y/n]: " extra; extra=${extra:-y}; fi
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then expire="${EXPIRE:-0}"; else read -rp "Masa aktif (30d, 2w, 1m, 2026-12-31, kosong=tanpa): " expire; fi
  exp_epoch=$(parse_duration "${expire:-0}") || { err "Format expired invalid."; return 1; }
  owner="${OWNER:--}"
  [[ "${#owner}" -le 60 && "$owner" != *"|"* && "$owner" != *$'\n'* && "$owner" != *$'\r'* ]] || { err "Owner maksimal 60 karakter dan tidak boleh berisi delimiter/newline."; return 1; }

  quota="${BW_QUOTA_GB:-$(conf_get BANDWIDTH_DEFAULT_QUOTA_GB)}"; rate="${BW_LIMIT_MBIT:-${BW_RATE_MBIT:-$(conf_get BANDWIDTH_DEFAULT_RATE_MBIT)}}"
  quota="${quota:-0}"; rate="${rate:-0}"
  [[ "${#quota}" -le 16 && "$quota" =~ ^[0-9]+([.][0-9]{1,3})?$ ]] || { err "BW_QUOTA_GB harus angka GB dengan maksimal 3 desimal."; return 1; }
  awk -v g="$quota" 'BEGIN { exit !(g >= 0 && g <= 1000000) }' || { err "BW_QUOTA_GB maksimum 1000000 GB."; return 1; }
  [[ "${#rate}" -le 16 ]] || { err "BW_LIMIT_MBIT terlalu panjang."; return 1; }
  normalized=$(bandwidth_rate_normalize "$rate") || { err "BW_LIMIT_MBIT harus angka Mbps."; return 1; }
  awk -v r="$normalized" 'BEGIN { exit !(r >= 0 && r <= 100000) }' || { err "BW_LIMIT_MBIT maksimum 100000 Mbps."; return 1; }
  quota_bytes=$(awk -v g="$quota" 'BEGIN{printf "%.0f", g*1000000000}')
  [[ "$plan" == "shared" && "${BW_LIMIT_MBIT:-0}" != "0" && -n "${BW_LIMIT_MBIT:-}" ]] && warn "Shared tetap boleh punya rate limit; auto-suspend tetap aktif untuk CPU/RAM."

  ip=$(next_ip) || { err "IP habis."; return 1; }
  local -a alloc
  plist=$(alloc_ports "$nports") || { err "Port kontigu kosong tidak cukup (butuh ${nports})."; return 1; }
  # alloc_ports mengeluarkan satu port per baris; `read -a` hanya membaca baris pertama,
  # sehingga dulu hanya port SSH yang terbuka. mapfile membaca semua baris.
  mapfile -t alloc <<< "$plist"
  (( ${#alloc[@]} == nports )) || { err "Alokasi port tidak lengkap (${#alloc[@]}/${nports})."; return 1; }
  ssh_port=${alloc[0]}
  portmap="tcp:${ssh_port}:22"
  for p in "${alloc[@]:1}"; do portmap+=",tcp:${p}:${p},udp:${p}:${p}"; done

  info "Membuat ${name} [${plan}/${vtype}] (${img}) ${cpu}CPU/${ram}MB/${disk}GB → ${ip}"
  if ! lxc init "$img" "$name" $vmflag -p "$PROFILE" -s "$POOL"; then
    err "Gagal init guest."
    # If init left a partial object behind, reserve resources if cleanup fails.
    lxc info "$name" >/dev/null 2>&1 && _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"
    return 1
  fi
  lxc config set "$name" limits.cpu "$cpu" || { err "Gagal menerapkan limit CPU."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
  lxc config set "$name" limits.memory "${ram}MB" || { err "Gagal menerapkan limit RAM."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
  if ! lxc config device override "$name" root size="${disk}GB" 2>/dev/null && ! lxc config device set "$name" root size "${disk}GB"; then
    err "Gagal mengatur ukuran disk ${disk}GB; VPS baru dibatalkan."
    _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"
    return 1
  fi
  effective_disk=$(lxc config device get "$name" root size 2>/dev/null)
  if [[ ! "$effective_disk" =~ ^${disk}([.]0+)?GB$ && "$effective_disk" != "${disk}GB" ]]; then
    err "Konfigurasi disk efektif tidak cocok (diminta ${disk}GB, diterapkan ${effective_disk:-unknown}); create dibatalkan."
    _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"
    return 1
  fi
  lxc config set "$name" boot.autostart true || { err "Gagal mengaktifkan boot.autostart."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
  if [[ "$vtype" == "container" ]]; then
    lxc config set "$name" limits.memory.swap false || { err "Gagal mematikan memory swap."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
    if [[ "${extra,,}" == "y" ]]; then
      lxc config set "$name" security.nesting true || { err "Gagal mengaktifkan nesting."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
      lxc config set "$name" security.syscalls.intercept.mknod true || { err "Gagal menerapkan mknod interception."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
      lxc config set "$name" security.syscalls.intercept.setxattr true || { err "Gagal menerapkan setxattr interception."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
    elif [[ "${extra,,}" != "n" ]]; then
      err "NESTING harus y/n."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1
    fi
  else
    lxc config set "$name" security.secureboot false || { err "Gagal menerapkan konfigurasi VM."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
  fi
  set_static_ip "$name" "$ip" || { err "Gagal reservasi IP."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }
  if ! lxc start "$name"; then
    err "Gagal start setelah konfigurasi resource diterapkan. Batas disk dipertahankan; VPS dibatalkan."
    _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"
    return 1
  fi

  wait_guest "$name" || warn "Guest belum responsif; lanjut setup."
  wait_ip "$name" "$ip" || true
  setup_guest "$name" "$pass" || { err "Gagal setup SSH/password guest; VPS baru dibatalkan."; _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"; return 1; }

  db_add "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$(date +%F)" "$vtype" "$exp_epoch" "$owner" 0 "$plan" "$quota_bytes" "$normalized" || {
    err "Gagal menyimpan data VPS ke database."
    _vps_create_cleanup "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$vtype" "$exp_epoch" "$owner" "$plan" "$quota_bytes" "$normalized"
    return 1
  }
  persisted_ports=$(db_field "$name" 7 | awk -F, '{ for (i=1; i<=NF; i++) { if (split($i,a,":") == 3) seen[a[2]]=1 } } END { for (p in seen) count++; print count+0 }')
  if [[ ! "$persisted_ports" =~ ^[0-9]+$ ]] || (( persisted_ports != nports )); then
    err "BUG PORT: diminta ${nports}, tetapi database hanya menyimpan ${persisted_ports:-0} port. VPS dibatalkan agar tidak dibuat setengah jadi."
    db_set_fields "$name" "13=1" "25=provisioning-failed" || true
    _vps_purge_body "$name" || warn "Gagal membersihkan create tidak konsisten; reservasi dipertahankan agar port tidak dipakai ulang."
    return 1
  fi
  info "Jumlah port tersimpan: ${persisted_ports}/${nports}."
  bandwidth_apply_tc "$name" >/dev/null 2>&1 || warn "TC bandwidth belum diterapkan untuk ${name}; periksa konfigurasi bandwidth."
  if ! apply_all_rules; then
    err "Firewall gagal diterapkan. Provisioning tidak dilaporkan sukses; record/port tetap dipertahankan bila cleanup firewall gagal."
    _vps_purge_body "$name" || warn "Cleanup belum tuntas. Record dipertahankan untuk mencegah IP/port dipakai ulang; jalankan vpsnat restore setelah memperbaiki firewall."
    return 1
  fi
  db_set_fields "$name" "23=0" "24=0" "20=0" "21=0" "22=$(date +%s)" || warn "VPS ${name} dan port telah dibuat, tetapi metadata traffic gagal diperbarui; jalankan sync/monitor dan jangan ulangi create."

  echo
  ok "VPS ${name} dibuat (${plan})."
  vps_info "$name"
  info "Port aplikasi (${#alloc[@]} total termasuk SSH): ${alloc[*]:1} (otomatis kontigu)."
}

vps_create() {
  with_alloc_lock _vps_create_locked "$@"
}

vps_list() {
  printf "${W}%-14s %-10s %-10s %-10s %-14s %-4s %-6s %-5s %-7s %-10s${N}\n" NAME PLAN TYPE STATE IP CPU RAM DISK SSH BW
  echo "------------------------------------------------------------------------------------------------"
  [[ ! -s "$DB_FILE" ]] && { echo "(kosong)"; return; }
  local name ip ssh cpu ram disk vt exp susp plan quota rx tx rate qs high pc pt prx ptx reason state bw
  while IFS='|' read -r name ip ssh cpu ram disk _ _ _ vt exp _ susp plan quota rx tx rate qs high pc pt prx ptx reason; do
    [[ -z "$name" ]] && continue
    state=$(vps_state "$name"); [[ -z "$state" ]] && state="MISSING"
    [[ "${susp:-0}" == "1" ]] && state="SUSPEND"
    quota=${quota:-0}; rx=${rx:-0}; tx=${tx:-0}; rate=${rate:-0}
    bw="$(bandwidth_fmt_bytes "$((rx + tx))")"
    (( quota > 0 )) && bw="${bw}/$(awk -v q="$quota" 'BEGIN{printf "%g", q/1000000000}')GB" || bw="${bw}/∞"
    case "$state" in RUNNING) state="${G}RUNNING${N}";; STOPPED) state="${R}STOPPED${N}";; SUSPEND) state="${Y}SUSPEND${N}";; esac
    printf "%-14s %-10s %-10s %-19b %-14s %-4s %-6s %-5s %-7s %-10s\n" "$name" "${plan:-shared}" "${vt:-container}" "$state" "$ip" "$cpu" "${ram}M" "${disk}G" "$ssh" "$bw"
  done < "$DB_FILE"
}

vps_info() {
  local name; name=$(pick_vps "${1:-}") || return 1
  local pubip ip ssh cpu ram disk ports pass created state vt exp owner susp plan quota rate reason
  pubip=$(pub_ip); ip=$(db_field "$name" 2); ssh=$(db_field "$name" 3); cpu=$(db_field "$name" 4); ram=$(db_field "$name" 5); disk=$(db_field "$name" 6)
  ports=$(db_field "$name" 7); pass=$(db_field "$name" 8); created=$(db_field "$name" 9); vt=$(vps_type "$name"); exp=$(db_field "$name" 11); owner=$(db_field "$name" 12); susp=$(db_field "$name" 13)
  plan=$(plan_type "$name"); quota=$(db_field "$name" 15); rate=$(db_field "$name" 18); reason=$(db_field "$name" 25); state=$(vps_state "$name")
  echo -e "${W}=== ${name} ===${N}"
  echo "Tipe layanan : ${plan}"
  echo "Backend      : ${vt}"
  echo "Status       : ${state:-?}$([[ "${susp:-0}" == "1" ]] && echo " (SUSPENDED: ${reason:--})")"
  echo "IP Lokal     : ${ip}"
  echo "Spesifikasi  : ${cpu} CPU / ${ram} MB RAM / ${disk} GB Disk"
  echo "Dibuat       : ${created}"
  echo "Expired      : $(fmt_epoch "${exp:-0}") ($(remain_str "${exp:-0}"))"
  [[ -n "$owner" && "$owner" != "-" ]] && echo "Owner        : ${owner}"
  echo "SSH          : ssh root@${pubip} -p ${ssh}"
  echo "Password     : ${pass}"
  echo "Bandwidth    :"; bandwidth_status "$name"
  if [[ "${plan:-shared}" == "shared" ]]; then
    echo "Auto suspend : CPU/RAM ${RESOURCE_THRESHOLD_DEFAULT}% selama $(cfg_int SHARED_SUSPEND_MINUTES "$SHARED_SUSPEND_MINUTES_DEFAULT") menit"
  else
    echo "Auto suspend : disabled untuk limit CPU/RAM"
  fi
  echo "Port map     :"
  echo "${ports//,/$'\n'}" | awk -F: -v ip="$pubip" 'NF==3{k=$2":"$3; if(!(k in pr)){order[++n]=k; pr[k]=$1} else {pr[k]=pr[k]"+"$1}} END{for(i=1;i<=n;i++){split(order[i],a,":"); printf "  %-8s %s:%s -> %s\n", pr[order[i]], ip, a[1], a[2]}}'
}

_vps_start_locked() {
  need_root; local n reason; n=$(pick_vps "${1:-}") || return 1
  if [[ "$(db_field "$n" 13)" == "1" ]]; then reason=$(db_field "$n" 25); err "$n sedang suspended (${reason:--}). Lakukan unsuspend setelah syarat suspension selesai."; return 1; fi
  lxc start "$n" && { bandwidth_apply_tc "$n" >/dev/null 2>&1 || true; ok "$n start."; }
}

vps_start() { with_alloc_lock _vps_start_locked "$@"; }


_vps_stop_locked() {
  need_root
  local n
  n=$(pick_vps "${1:-}") || return 1
  if lxc stop "$n" --timeout 30; then
    ok "$n stop."
    return 0
  fi
  lxc stop "$n" --force && ok "$n stop (force)."
}

vps_stop() { with_alloc_lock _vps_stop_locked "$@"; }


_vps_restart_locked() {
  need_root
  local n
  n=$(pick_vps "${1:-}") || return 1
  if [[ "$(db_field "$n" 13)" == "1" ]]; then
    local reason
    reason=$(db_field "$n" 25)
    err "$n sedang suspended (${reason:--}). Lakukan unsuspend terlebih dahulu."
    return 1
  fi
  if ! lxc restart "$n" --timeout 30; then
    lxc stop "$n" --force 2>/dev/null || true
    lxc start "$n" || return 1
  fi
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || true
  ok "$n restart."
}

vps_restart() { with_alloc_lock _vps_restart_locked "$@"; }


_vps_purge_body() {
  local n="$1" record
  record=$(db_get "$n") || { err "Record ${n} tidak ditemukan; purge dibatalkan."; return 1; }
  [[ -n "$record" ]] || { err "Record ${n} tidak ditemukan; purge dibatalkan."; return 1; }
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || true
  # Never free IP/ports if LXD still has the guest or delete failed.
  if lxc info "$n" >/dev/null 2>&1; then
    lxc delete "$n" --force || { err "Gagal menghapus guest LXD ${n}; reservasi tetap disimpan."; return 1; }
  fi
  db_del "$n" || { err "Gagal menghapus record ${n}; reservasi tetap dipertahankan bila tersedia."; return 1; }
  if ! apply_all_rules; then
    # Keep a reservation row until firewall reconciliation succeeds; prevents unsafe reuse.
    with_lock _vpsnat_restore_record "$record" || err "GAGAL memulihkan reservasi DB untuk ${n}; lakukan pemulihan manual segera."
    err "Firewall gagal direkonsiliasi setelah purge ${n}; reservasi dipulihkan."
    return 1
  fi
  rm -f "${MONITOR_DIR}/${n}.state" 2>/dev/null || true
  rm -f "${NOTIF_DIR}/${n}."* 2>/dev/null || true
  return 0
}

_vpsnat_restore_record() {
  local record="$1" safe
  # On uncertain purge/firewall failure, restore a suspended reservation, never an active ghost VPS.
  safe=$(printf '%s\n' "$record" | awk -F'|' -v OFS='|' '{while (NF<25) $(NF+1)=""; $13=1; $25="purge-firewall-failed"; print}') || return 1
  [[ -n "$safe" ]] || return 1
  printf '%s\n' "$safe" >> "$DB_FILE"
}
_vps_purge() { with_alloc_lock _vps_purge_body "$@"; }

_vps_resize_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local cpu ram disk vt ncpu nram ndisk effective rollback_failed=0
  cpu=$(db_field "$n" 4); ram=$(db_field "$n" 5); disk=$(db_field "$n" 6); vt=$(vps_type "$n")
  if [[ "$NONINTERACTIVE" == "1" ]]; then ncpu="${CPU:-$cpu}"; nram="${RAM:-$ram}"; ndisk="${DISK:-$disk}"; else read -rp "CPU [${cpu}]: " ncpu; ncpu=${ncpu:-$cpu}; read -rp "RAM MB [${ram}]: " nram; nram=${nram:-$ram}; read -rp "Disk GB [${disk}] (naik saja): " ndisk; ndisk=${ndisk:-$disk}; fi
  [[ "$ncpu" =~ ^[0-9]{1,3}$ && "$nram" =~ ^[0-9]{1,7}$ && "$ndisk" =~ ^[0-9]{1,5}$ && "$disk" =~ ^[0-9]{1,5}$ ]] || { err "CPU/RAM/Disk harus integer dengan panjang valid."; return 1; }
  ncpu=$((10#$ncpu)); nram=$((10#$nram)); ndisk=$((10#$ndisk)); disk=$((10#$disk))
  (( ncpu >= 1 && ncpu <= 128 && nram >= 128 && nram <= 1048576 && ndisk >= disk && ndisk <= 10000 )) || { err "Resource di luar batas atau disk tidak boleh turun."; return 1; }

  if ! lxc config set "$n" limits.cpu "$ncpu"; then err "Gagal mengubah CPU; database tidak berubah."; return 1; fi
  if ! lxc config set "$n" limits.memory "${nram}MB"; then
    lxc config set "$n" limits.cpu "$cpu" >/dev/null 2>&1 || { rollback_failed=1; warn "Rollback CPU gagal."; }
    (( rollback_failed == 0 )) || { db_set_fields "$n" "13=1" "25=resize-rollback-failed" || true; apply_all_rules || true; }
    err "Gagal mengubah RAM; rollback resource lama ${n} $( ((rollback_failed)) && echo 'tidak lengkap' || echo 'selesai' )."; return 1
  fi
  if ! lxc config device set "$n" root size "${ndisk}GB" 2>/dev/null && ! lxc config device override "$n" root size="${ndisk}GB"; then
    lxc config set "$n" limits.cpu "$cpu" >/dev/null 2>&1 || { rollback_failed=1; warn "Rollback CPU gagal."; }
    lxc config set "$n" limits.memory "${ram}MB" >/dev/null 2>&1 || { rollback_failed=1; warn "Rollback RAM gagal."; }
    if (( rollback_failed )); then db_set_fields "$n" "13=1" "25=resize-rollback-failed" || true; apply_all_rules || true; fi
    err "Gagal mengubah disk; database tidak diubah. Rollback $( ((rollback_failed)) && echo 'tidak lengkap; VPS disuspend untuk rekonsiliasi' || echo 'resource berhasil' )."; return 1
  fi
  effective=$(lxc config device get "$n" root size 2>/dev/null)
  if [[ ! "$effective" =~ ^${ndisk}([.]0+)?GB$ ]]; then
    err "Disk efektif tidak sesuai (diminta ${ndisk}GB, aktual ${effective:-unknown})."
    if ! lxc config device set "$n" root size "${disk}GB" 2>/dev/null && ! lxc config device override "$n" root size="${disk}GB"; then rollback_failed=1; fi
    lxc config set "$n" limits.cpu "$cpu" >/dev/null 2>&1 || rollback_failed=1
    lxc config set "$n" limits.memory "${ram}MB" >/dev/null 2>&1 || rollback_failed=1
    if (( rollback_failed )); then db_set_fields "$n" "13=1" "25=resize-rollback-failed" || true; apply_all_rules || true; warn "Rollback gagal lengkap; resource mismatch dicatat dengan VPS suspended."; fi
    return 1
  fi
  if ! db_set_fields "$n" "4=$ncpu" "5=$nram" "6=$ndisk" "20=0" "21=0" "22=$(date +%s)"; then
    err "Gagal menyimpan resource baru ke DB; dicoba rollback LXD ke nilai lama."
    if ! lxc config device set "$n" root size "${disk}GB" 2>/dev/null && ! lxc config device override "$n" root size="${disk}GB"; then rollback_failed=1; fi
    lxc config set "$n" limits.cpu "$cpu" >/dev/null 2>&1 || rollback_failed=1
    lxc config set "$n" limits.memory "${ram}MB" >/dev/null 2>&1 || rollback_failed=1
    if (( rollback_failed )); then db_set_fields "$n" "13=1" "25=resize-rollback-failed" || true; apply_all_rules || true; err "Rollback tidak lengkap; ${n} disuspend dan wajib direkonsiliasi."; fi
    return 1
  fi
  if [[ "$vt" == "vm" ]]; then ok "Resource ${n} diperbarui. Restart VM bila guest OS belum melihat perubahan CPU/RAM."; else ok "Resource ${n} diperbarui (live)."; fi
}

vps_resize() { with_alloc_lock _vps_resize_locked "$@"; }

_vps_clone_locked() {
  need_root
  local src new; src=$(pick_vps "${1:-}") || return 1; new="${2:-${NEWNAME:-}}"; [[ -z "$new" ]] && ask new "Nama VPS baru: "
  [[ "$new" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Nama tidak valid."; return 1; }
  [[ -n "$(db_get "$new")" || -n "$(lxc info "$new" 2>/dev/null)" ]] && { err "Nama sudah dipakai di DB/LXD."; return 1; }
  local ip ssh cpu ram disk pass vt exp owner plan quota rate ports effective
  ip=$(next_ip) || { err "IP habis."; return 1; }; ssh=$(next_ssh_port) || { err "Port habis."; return 1; }
  cpu=$(db_field "$src" 4); ram=$(db_field "$src" 5); disk=$(db_field "$src" 6); pass=$(db_field "$src" 8); vt=$(vps_type "$src"); exp=$(db_field "$src" 11); owner=$(db_field "$src" 12); plan=$(plan_type "$src"); quota=$(db_field "$src" 15); rate=$(db_field "$src" 18); ports="tcp:${ssh}:22"
  if ! lxc copy "$src" "$new"; then
    err "Gagal clone."
    lxc info "$new" >/dev/null 2>&1 && _vps_create_cleanup "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$vt" "${exp:-0}" "${owner:--}" "${plan:-shared}" "${quota:-0}" "${rate:-0}"
    return 1
  fi
  set_static_ip "$new" "$ip" || { err "Gagal menerapkan IP clone."; _vps_create_cleanup "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$vt" "${exp:-0}" "${owner:--}" "${plan:-shared}" "${quota:-0}" "${rate:-0}"; return 1; }
  effective=$(lxc config device get "$new" root size 2>/dev/null)
  if [[ ! "$effective" =~ ^${disk}([.]0+)?GB$ ]]; then err "Disk efektif clone tidak cocok dengan database (${effective:-unknown}); clone dibatalkan."; _vps_create_cleanup "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$vt" "${exp:-0}" "${owner:--}" "${plan:-shared}" "${quota:-0}" "${rate:-0}"; return 1; fi
  lxc start "$new" || { err "Gagal start clone."; _vps_create_cleanup "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$vt" "${exp:-0}" "${owner:--}" "${plan:-shared}" "${quota:-0}" "${rate:-0}"; return 1; }
  if ! wait_guest "$new" || ! wait_ip "$new" "$ip"; then
    err "Clone belum siap atau IP belum terpasang; dibatalkan."
    _vps_create_cleanup "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$vt" "${exp:-0}" "${owner:--}" "${plan:-shared}" "${quota:-0}" "${rate:-0}"
    return 1
  fi
  db_add "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$(date +%F)" "$vt" "${exp:-0}" "${owner:--}" 0 "${plan:-shared}" "${quota:-0}" "${rate:-0}" || {
    err "Gagal mendaftarkan clone ke DB."
    _vps_create_cleanup "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "$ports" "$pass" "$vt" "${exp:-0}" "${owner:--}" "${plan:-shared}" "${quota:-0}" "${rate:-0}"
    return 1
  }
  bandwidth_apply_tc "$new" >/dev/null 2>&1 || warn "TC bandwidth clone belum diterapkan."
  if ! apply_all_rules; then
    db_set_fields "$new" "13=1" "25=clone-firewall-failed" || true
    lxc stop "$new" --force >/dev/null 2>&1 || true
    apply_all_rules || warn "Firewall rollback clone gagal; record dan port tetap dicadangkan."
    err "Firewall gagal setelah clone; clone ditahan sebagai suspended untuk rekonsiliasi."; return 1
  fi
  ok "Clone selesai."; vps_info "$new"
}

vps_clone() {
  with_alloc_lock _vps_clone_locked "$@"
}

_vps_set_plan_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local plan="${2:-}"
  if [[ -z "$plan" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then plan="${PLAN_TYPE:-shared}"; else read -rp "Tipe layanan (shared/dedicated) [$(plan_type "$n")]: " plan; plan=${plan:-$(plan_type "$n")}; fi
  fi
  [[ "$plan" =~ ^(shared|dedicated)$ ]] || { err "Tipe harus shared atau dedicated."; return 1; }
  db_set_fields "$n" "14=$plan" "20=0" "21=0" "22=$(date +%s)" || { err "Gagal menyimpan tipe layanan ${n}."; return 1; }
  # Mengubah plan tidak boleh menghapus alasan/status suspension yang sudah ada.
  ok "${n}: tipe layanan ${plan}."
}

vps_set_plan() { with_alloc_lock _vps_set_plan_locked "$@"; }


vps_reinstall() { with_alloc_lock _vps_reinstall_locked "$@"; }

_vps_reinstall_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local img_key img cpu ram disk ip pass vt vmflag="" plan quota rate ports exp owner
  confirm "Reinstall ${n}? SEMUA DATA GUEST HILANG." || { info "Batal."; return 0; }
  vt=$(vps_type "$n"); [[ "$vt" == "vm" ]] && vmflag="--vm"
  if [[ "$NONINTERACTIVE" == "1" ]]; then img_key="${IMG_KEY:-ubuntu22}"; else echo "Image: ubuntu24 | ubuntu22 | ubuntu20 | debian12 | debian11 | alma9 | rocky9 | alpine"; read -rp "Image [ubuntu22]: " img_key; img_key=${img_key:-ubuntu22}; fi
  img=$(image_for "$img_key"); ip=$(db_field "$n" 2); cpu=$(db_field "$n" 4); ram=$(db_field "$n" 5); disk=$(db_field "$n" 6); pass=$(gen_pass); plan=$(plan_type "$n"); quota=$(db_field "$n" 15); rate=$(db_field "$n" 18); ports=$(ports_get "$n"); exp=$(db_field "$n" 11); owner=$(db_field "$n" 12)
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || true
  lxc delete "$n" --force || { err "Gagal menghapus guest lama."; return 1; }
  lxc init "$img" "$n" $vmflag -p "$PROFILE" -s "$POOL" || { db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "Gagal init reinstall; DB tetap reservasi dan VPS disuspend untuk rekonsiliasi."; return 1; }
  if ! lxc config set "$n" limits.cpu "$cpu" || ! lxc config set "$n" limits.memory "${ram}MB"; then
    lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "Gagal menerapkan CPU/RAM reinstall."; return 1
  fi
  if ! lxc config device override "$n" root size="${disk}GB" 2>/dev/null && ! lxc config device set "$n" root size "${disk}GB"; then
    err "Gagal mengatur ukuran disk saat reinstall; guest baru tidak dijalankan."
    lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true
    return 1
  fi
  local effective_disk; effective_disk=$(lxc config device get "$n" root size 2>/dev/null)
  if [[ "$effective_disk" != "${disk}GB" ]]; then
    err "Ukuran disk efektif reinstall tidak cocok (${effective_disk:-unknown}); VPS disuspend untuk rekonsiliasi."
    lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; return 1
  fi
  lxc config set "$n" boot.autostart true || { lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; return 1; }
  if [[ "$vt" == "container" ]]; then
    lxc config set "$n" limits.memory.swap false || { lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; return 1; }
    lxc config set "$n" security.nesting true || { lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; return 1; }
  else
    lxc config set "$n" security.secureboot false || { lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; return 1; }
  fi
  set_static_ip "$n" "$ip" || { lxc delete "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; return 1; }
  lxc start "$n" || { db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "Guest reinstall gagal start; VPS disuspend dan reservasi dipertahankan."; return 1; }
  wait_guest "$n" || { lxc stop "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "Guest reinstall belum responsif; VPS disuspend."; return 1; }
  wait_ip "$n" "$ip" || { lxc stop "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "IP guest reinstall belum terpasang; VPS disuspend."; return 1; }
  setup_guest "$n" "$pass" || { lxc stop "$n" --force 2>/dev/null || true; db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "Setup guest reinstall gagal; VPS disuspend."; return 1; }
  db_set_fields "$n" "8=$pass" "13=0" "14=${plan:-shared}" "15=${quota:-0}" "18=${rate:-0}" "20=0" "21=0" "22=$(date +%s)" "23=0" "24=0" "25=-" || { db_set_fields "$n" "13=1" "25=reinstall-failed" || true; apply_all_rules || true; err "Gagal menyimpan metadata reinstall; VPS disuspend."; return 1; }
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || warn "TC bandwidth reinstall belum diterapkan."
  apply_all_rules || { db_set_fields "$n" "13=1" "25=reinstall-failed" || true; err "Firewall reinstall gagal; VPS disuspend dan port tetap dicadangkan."; return 1; }
  ok "Reinstall ${n} selesai."; vps_info "$n"
}
