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
vps_delete() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  confirm "HAPUS ${n} beserta datanya?" || { info "Batal."; return; }
  _vps_purge "$n"
  ok "$n dihapus."
}

vps_passwd() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local pass
  if [[ "$NONINTERACTIVE" == "1" ]]; then pass="${PASS:-$(gen_pass)}"
  else read -rp "Password baru [random]: " pass; pass=${pass:-$(gen_pass)}; fi
  [[ "$pass" == *"|"* ]] && { err "Password tidak boleh mengandung karakter |"; return 1; }
  printf 'root:%s\n' "$pass" | lxc exec "$n" -- chpasswd || { err "Gagal."; return 1; }
  db_set_field "$n" 8 "$pass"
  ok "Password ${n}: ${pass}"
}

vps_create() {
  need_root
  local name img_key img cpu ram disk pass ssh_port ip extra vtype="container" vmflag="" nports t expire owner exp_epoch
  local plan quota quota_bytes rate normalized plist portmap p
  name="${1:-${NAME:-}}"
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

  CPU="${CPU:-}"; ask cpu "CPU core [1]: " 1
  RAM="${RAM:-}"; ask ram "RAM MB [1024]: " 1024
  DISK="${DISK:-}"; ask disk "Disk GB [10]: " 10
  [[ "$cpu" =~ ^[0-9]+$ && "$ram" =~ ^[0-9]+$ && "$disk" =~ ^[0-9]+$ ]] || { err "CPU/RAM/Disk harus angka."; return 1; }
  (( cpu >= 1 && ram >= 128 && disk >= 1 )) || { err "Minimal 1 CPU, 128 MB RAM, 1 GB disk."; return 1; }

  if [[ "$NONINTERACTIVE" == "1" ]]; then pass="${PASS:-$(gen_pass)}"; else read -rp "Root password [random]: " pass; pass=${pass:-$(gen_pass)}; fi
  [[ "$pass" == *"|"* ]] && { err "Password tidak boleh mengandung karakter |"; return 1; }

  if [[ "$NONINTERACTIVE" == "1" ]]; then nports="${NPORTS:-3}"; else read -rp "Jumlah port total (${VPS_PORTS_MIN}-${VPS_PORTS_MAX}) [3]: " nports; nports=${nports:-3}; fi
  [[ "$nports" =~ ^[0-9]+$ ]] && (( nports >= VPS_PORTS_MIN && nports <= VPS_PORTS_MAX )) || { err "Jumlah port harus ${VPS_PORTS_MIN}-${VPS_PORTS_MAX}."; return 1; }

  if [[ "$vtype" == "container" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then extra="${NESTING:-y}"; else read -rp "Aktifkan nesting (Docker di dalam VPS)? [Y/n]: " extra; extra=${extra:-y}; fi
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then expire="${EXPIRE:-0}"; else read -rp "Masa aktif (30d, 2w, 1m, 2026-12-31, kosong=tanpa): " expire; fi
  exp_epoch=$(parse_duration "${expire:-0}") || { err "Format expired invalid."; return 1; }
  owner="${OWNER:--}"

  quota="${BW_QUOTA_GB:-$(conf_get BANDWIDTH_DEFAULT_QUOTA_GB)}"; rate="${BW_LIMIT_MBIT:-${BW_RATE_MBIT:-$(conf_get BANDWIDTH_DEFAULT_RATE_MBIT)}}"
  quota="${quota:-0}"; rate="${rate:-0}"
  [[ "$quota" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "BW_QUOTA_GB harus angka GB."; return 1; }
  normalized=$(bandwidth_rate_normalize "$rate") || { err "BW_LIMIT_MBIT harus angka Mbps."; return 1; }
  quota_bytes=$(awk -v g="$quota" 'BEGIN{printf "%.0f", g*1000000000}')
  [[ "$plan" == "shared" && "${BW_LIMIT_MBIT:-0}" != "0" && -n "${BW_LIMIT_MBIT:-}" ]] && warn "Shared tetap boleh punya rate limit; auto-suspend tetap aktif untuk CPU/RAM."

  ip=$(next_ip) || { err "IP habis."; return 1; }
  local -a alloc
  plist=$(alloc_ports "$nports") || { err "Port kontigu kosong tidak cukup (butuh ${nports})."; return 1; }
  read -ra alloc <<< "$plist"
  ssh_port=${alloc[0]}

  info "Membuat ${name} [${plan}/${vtype}] (${img}) ${cpu}CPU/${ram}MB/${disk}GB → ${ip}"
  lxc init "$img" "$name" $vmflag -p "$PROFILE" -s "$POOL" || { err "Gagal init."; return 1; }
  lxc config set "$name" limits.cpu "$cpu" || { lxc delete "$name" --force; return 1; }
  lxc config set "$name" limits.memory "${ram}MB" || { lxc delete "$name" --force; return 1; }
  lxc config device override "$name" root size="${disk}GB" 2>/dev/null || lxc config device set "$name" root size "${disk}GB"
  lxc config set "$name" boot.autostart true
  if [[ "$vtype" == "container" ]]; then
    lxc config set "$name" limits.memory.swap false
    if [[ "${extra,,}" == "y" ]]; then
      lxc config set "$name" security.nesting true
      lxc config set "$name" security.syscalls.intercept.mknod true
      lxc config set "$name" security.syscalls.intercept.setxattr true
    fi
  else
    lxc config set "$name" security.secureboot false
  fi
  set_static_ip "$name" "$ip" || { err "Gagal reservasi IP."; lxc delete "$name" --force; return 1; }
  if ! lxc start "$name"; then
    warn "Start gagal, retry tanpa limit disk..."
    lxc config device unset "$name" root size 2>/dev/null || true
    lxc start "$name" || { err "Gagal start."; lxc delete "$name" --force; return 1; }
  fi

  wait_guest "$name" || warn "Guest belum responsif; lanjut setup."
  wait_ip "$name" "$ip" || true
  setup_guest "$name" "$pass"

  portmap="tcp:${ssh_port}:22"
  for p in "${alloc[@]:1}"; do portmap+=",tcp:${p}:${p},udp:${p}:${p}"; done

  db_add "$name" "$ip" "$ssh_port" "$cpu" "$ram" "$disk" "$portmap" "$pass" "$(date +%F)" "$vtype" "$exp_epoch" "$owner" 0 "$plan" "$quota_bytes" "$normalized"
  bandwidth_apply_tc "$name" >/dev/null 2>&1 || true
  apply_all_rules
  db_set_fields "$name" "23=0" "24=0" "20=0" "21=0" "22=$(date +%s)"

  echo
  ok "VPS ${name} dibuat (${plan})."
  vps_info "$name"
  info "Port aplikasi: ${alloc[*]:1} (otomatis kontigu)."
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
    (( quota > 0 )) && bw="${bw}/${quota}GB" || bw="${bw}/∞"
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

vps_start() {
  need_root; local n reason; n=$(pick_vps "${1:-}") || return 1
  if [[ "$(db_field "$n" 13)" == "1" ]]; then reason=$(db_field "$n" 25); err "$n sedang suspended (${reason:--}). Lakukan unsuspend setelah syarat suspension selesai."; return 1; fi
  lxc start "$n" && { bandwidth_apply_tc "$n" >/dev/null 2>&1 || true; ok "$n start."; }
}

vps_stop() {
  need_root
  local n
  n=$(pick_vps "${1:-}") || return 1
  if lxc stop "$n" --timeout 30; then
    ok "$n stop."
    return 0
  fi
  lxc stop "$n" --force && ok "$n stop (force)."
}

vps_restart() {
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

_vps_purge() {
  local n="$1" ports e proto ext int ip rest
  ip=$(db_field "$n" 2); ports=$(ports_get "$n")
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || true
  for e in ${ports//,/ }; do
    [[ "$e" == "-" ]] && continue
    proto=${e%%:*}; rest=${e#*:}; ext=${rest%%:*}; int=${rest#*:}; fw_del_forward "$proto" "$ext" "$ip" "$int"
  done
  lxc delete "$n" --force 2>/dev/null || true
  db_del "$n"
  rm -f "${MONITOR_DIR}/${n}.state" 2>/dev/null || true
  fw_save
}

vps_resize() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local cpu ram disk vt ncpu nram ndisk
  cpu=$(db_field "$n" 4); ram=$(db_field "$n" 5); disk=$(db_field "$n" 6); vt=$(vps_type "$n")
  if [[ "$NONINTERACTIVE" == "1" ]]; then ncpu="${CPU:-$cpu}"; nram="${RAM:-$ram}"; ndisk="${DISK:-$disk}"; else read -rp "CPU [${cpu}]: " ncpu; ncpu=${ncpu:-$cpu}; read -rp "RAM MB [${ram}]: " nram; nram=${nram:-$ram}; read -rp "Disk GB [${disk}] (naik saja): " ndisk; ndisk=${ndisk:-$disk}; fi
  [[ "$ncpu" =~ ^[0-9]+$ && "$nram" =~ ^[0-9]+$ && "$ndisk" =~ ^[0-9]+$ ]] || { err "CPU/RAM/Disk harus angka."; return 1; }
  (( ncpu >= 1 && nram >= 128 && ndisk >= disk )) || { err "Resource tidak valid / disk tidak boleh turun."; return 1; }
  lxc config set "$n" limits.cpu "$ncpu" || return 1
  lxc config set "$n" limits.memory "${nram}MB" || return 1
  lxc config device set "$n" root size "${ndisk}GB" 2>/dev/null || lxc config device override "$n" root size="${ndisk}GB"
  db_set_fields "$n" "4=$ncpu" "5=$nram" "6=$ndisk" "20=0" "21=0" "22=$(date +%s)"
  if [[ "$vt" == "vm" ]]; then ok "Resource ${n} diperbarui. Restart VM bila guest OS belum melihat perubahan CPU/RAM."; else ok "Resource ${n} diperbarui (live)."; fi
}

vps_clone() {
  need_root
  local src new; src=$(pick_vps "${1:-}") || return 1; new="${2:-${NEWNAME:-}}"; [[ -z "$new" ]] && ask new "Nama VPS baru: "
  [[ "$new" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Nama tidak valid."; return 1; }
  [[ -n "$(db_get "$new")" ]] && { err "Nama sudah ada."; return 1; }
  local ip ssh cpu ram disk pass vt exp owner plan quota rate; ip=$(next_ip) || { err "IP habis."; return 1; }; ssh=$(next_ssh_port) || { err "Port habis."; return 1; }
  cpu=$(db_field "$src" 4); ram=$(db_field "$src" 5); disk=$(db_field "$src" 6); pass=$(db_field "$src" 8); vt=$(vps_type "$src"); exp=$(db_field "$src" 11); owner=$(db_field "$src" 12); plan=$(plan_type "$src"); quota=$(db_field "$src" 15); rate=$(db_field "$src" 18)
  lxc copy "$src" "$new" || { err "Gagal clone."; return 1; }
  set_static_ip "$new" "$ip" || { err "Gagal IP."; lxc delete "$new" --force; return 1; }
  lxc start "$new" || { err "Gagal start."; lxc delete "$new" --force; return 1; }
  wait_guest "$new" || true; wait_ip "$new" "$ip" || true
  db_add "$new" "$ip" "$ssh" "$cpu" "$ram" "$disk" "-" "$pass" "$(date +%F)" "$vt" "${exp:-0}" "${owner:--}" 0 "${plan:-shared}" "${quota:-0}" "${rate:-0}"
  ports_add_entry "$new" "tcp:${ssh}:22"
  bandwidth_apply_tc "$new" >/dev/null 2>&1 || true
  apply_all_rules
  ok "Clone selesai."; vps_info "$new"
}

vps_set_plan() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local plan="${2:-}"
  if [[ -z "$plan" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then plan="${PLAN_TYPE:-shared}"; else read -rp "Tipe layanan (shared/dedicated) [$(plan_type "$n")]: " plan; plan=${plan:-$(plan_type "$n")}; fi
  fi
  [[ "$plan" =~ ^(shared|dedicated)$ ]] || { err "Tipe harus shared atau dedicated."; return 1; }
  db_set_fields "$n" "14=$plan" "20=0" "21=0" "22=$(date +%s)"
  if [[ "$plan" == "dedicated" ]]; then db_set_field "$n" 25 -; fi
  ok "${n}: tipe layanan ${plan}."
}

vps_reinstall() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local img_key img cpu ram disk ip pass vt vmflag="" plan quota rate ports exp owner
  confirm "Reinstall ${n}? SEMUA DATA GUEST HILANG." || { info "Batal."; return 0; }
  vt=$(vps_type "$n"); [[ "$vt" == "vm" ]] && vmflag="--vm"
  if [[ "$NONINTERACTIVE" == "1" ]]; then img_key="${IMG_KEY:-ubuntu22}"; else echo "Image: ubuntu24 | ubuntu22 | ubuntu20 | debian12 | debian11 | alma9 | rocky9 | alpine"; read -rp "Image [ubuntu22]: " img_key; img_key=${img_key:-ubuntu22}; fi
  img=$(image_for "$img_key"); ip=$(db_field "$n" 2); cpu=$(db_field "$n" 4); ram=$(db_field "$n" 5); disk=$(db_field "$n" 6); pass=$(gen_pass); plan=$(plan_type "$n"); quota=$(db_field "$n" 15); rate=$(db_field "$n" 18); ports=$(ports_get "$n"); exp=$(db_field "$n" 11); owner=$(db_field "$n" 12)
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || true
  lxc delete "$n" --force || { err "Gagal menghapus guest lama."; return 1; }
  lxc init "$img" "$n" $vmflag -p "$PROFILE" -s "$POOL" || return 1
  lxc config set "$n" limits.cpu "$cpu"; lxc config set "$n" limits.memory "${ram}MB"
  lxc config device override "$n" root size="${disk}GB" 2>/dev/null || lxc config device set "$n" root size "${disk}GB"
  lxc config set "$n" boot.autostart true
  if [[ "$vt" == "container" ]]; then lxc config set "$n" limits.memory.swap false; lxc config set "$n" security.nesting true; else lxc config set "$n" security.secureboot false; fi
  set_static_ip "$n" "$ip" || return 1
  lxc start "$n" || return 1; wait_guest "$n" || true; wait_ip "$n" "$ip" || true; setup_guest "$n" "$pass"
  db_set_fields "$n" "8=$pass" "13=0" "14=${plan:-shared}" "15=${quota:-0}" "16=0" "17=0" "18=${rate:-0}" "19=0" "20=0" "21=0" "22=$(date +%s)" "23=0" "24=0" "25=-"
  bandwidth_apply_tc "$n" >/dev/null 2>&1 || true
  apply_all_rules
  ok "Reinstall ${n} selesai."; vps_info "$n"
}
