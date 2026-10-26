#!/usr/bin/env bash

# v3.4.0 — hardening host & VPS
#   * limits.processes (anti fork-bomb) + anti-spoofing NIC (MAC / IPv4 / IPv6 filtering)
#   * preflight ruang disk sebelum create / clone / snapshot / backup / restore-backup
#   * `vpsnat harden [nama|all] [--check]` untuk memeriksa / menerapkan hardening pada VPS lama
#
# Semua fungsi apply bersifat best-effort: kegagalan hardening tidak membatalkan create/clone,
# hanya memberi peringatan dan bisa diulang dengan `vpsnat harden <nama>`.

# ---------------------------------------------------------------------------
# Limit proses & anti-spoofing
# ---------------------------------------------------------------------------

# Limit proses sesuai plan. 0 = tanpa batas.
harden_proc_limit() {
  if [[ "${1:-shared}" == dedicated ]]; then
    cfg_int PROC_LIMIT_DEDICATED "$PROC_LIMIT_DEDICATED_DEFAULT"
  else
    cfg_int PROC_LIMIT_SHARED "$PROC_LIMIT_SHARED_DEFAULT"
  fi
}

# Set satu key pada NIC eth0 milik guest. Device yang masih diwarisi dari profile harus
# di-override dulu; device lokal cukup di-set.
nic_set() {
  local name="$1" key="$2" value="$3" out
  out=$(lxc config device set "$name" eth0 "$key" "$value" 2>&1) && return 0
  out=$(lxc config device override "$name" eth0 "${key}=${value}" 2>&1) && return 0
  warn "Gagal set eth0 ${key}=${value} pada ${name}: ${out}"
  return 1
}

# limits.processes hanya valid untuk container (VM tidak mengenalnya).
harden_apply_proc_limit() {
  local name="$1" plan="${2:-shared}" backend="${3:-container}" limit
  [[ "$backend" == container ]] || return 0
  limit=$(harden_proc_limit "$plan")
  if (( limit > 0 )); then
    lxc config set "$name" limits.processes "$limit" >/dev/null 2>&1 || {
      warn "Gagal set limits.processes=${limit} pada ${name}."
      return 1
    }
  else
    lxc config unset "$name" limits.processes >/dev/null 2>&1 || true
  fi
  return 0
}

harden_apply_antispoof() {
  local name="$1" k rc=0
  if (( $(cfg_int ANTISPOOF "$ANTISPOOF_DEFAULT") )); then
    nic_set "$name" security.mac_filtering true || rc=1
    nic_set "$name" security.ipv4_filtering true || rc=1
    # IPv6 best-effort: bridge VPSNAT memakai ipv6.address=none dan sebagian versi LXD menolak opsi ini.
    nic_set "$name" security.ipv6_filtering true >/dev/null 2>&1 || log "HARDEN ${name}: security.ipv6_filtering tidak diterapkan"
  else
    for k in security.mac_filtering security.ipv4_filtering security.ipv6_filtering; do
      lxc config device unset "$name" eth0 "$k" >/dev/null 2>&1 || true
    done
  fi
  return "$rc"
}

# Terapkan seluruh hardening pada satu guest. Return 1 bila ada langkah yang gagal.
vps_harden_apply() {
  local name="$1" plan="${2:-shared}" backend="${3:-container}" rc=0
  harden_apply_proc_limit "$name" "$plan" "$backend" || rc=1
  harden_apply_antispoof "$name" || rc=1
  return "$rc"
}

harden_nic_value() {
  local v
  v=$(lxc config device get "$1" eth0 "$2" 2>/dev/null)
  printf '%s' "${v:--}"
}

# Satu baris laporan status hardening. Return 1 bila belum sesuai kebijakan aktif.
harden_report_one() {
  local n="$1" plan backend want have mac v4 v6 verdict="OK"
  plan=$(plan_type "$n"); backend=$(vps_type "$n")
  if [[ "$backend" == container ]]; then
    want=$(harden_proc_limit "$plan"); [[ "$want" == 0 ]] && want="-"
    have=$(lxc config get "$n" limits.processes 2>/dev/null); have="${have:--}"
    [[ "$have" == "$want" ]] || verdict="BELUM"
  else
    want="n/a"; have="n/a"
  fi
  mac=$(harden_nic_value "$n" security.mac_filtering)
  v4=$(harden_nic_value "$n" security.ipv4_filtering)
  v6=$(harden_nic_value "$n" security.ipv6_filtering)
  if (( $(cfg_int ANTISPOOF "$ANTISPOOF_DEFAULT") )); then
    [[ "$mac" == true && "$v4" == true ]] || verdict="BELUM"
  fi
  printf '%-14s %-10s %-10s %-11s %-6s %-6s %-6s %s\n' "$n" "$plan" "$backend" "${have}/${want}" "$mac" "$v4" "$v6" "$verdict"
  [[ "$verdict" == OK ]]
}

# CLI: vpsnat harden [nama|all] [--check]
vps_harden() {
  need_root
  local target="" check=0 a n plan backend st running=0 total=0 bad=0
  local -a names=()
  for a in "$@"; do
    case "$a" in
      --check|-c|check) check=1 ;;
      *) [[ -z "$target" ]] && target="$a" ;;
    esac
  done
  if [[ -z "$target" ]]; then
    if (( check )); then
      target="all"
    elif [[ "$NONINTERACTIVE" == "1" ]]; then
      target="${NAME:-}"
      [[ -n "$target" ]] || { err "Pakai: vpsnat harden <nama|all> [--check]"; return 1; }
    else
      read -rp "Nama VPS atau 'all' [all]: " target
      target="${target:-all}"
    fi
  fi

  if [[ "$target" == all ]]; then
    mapfile -t names < <(awk -F'|' 'NF && $1 != "" {print $1}' "$DB_FILE" 2>/dev/null)
  else
    [[ -n "$(db_get "$target")" ]] || { err "VPS '${target}' tidak ditemukan."; return 1; }
    names=("$target")
  fi
  (( ${#names[@]} > 0 )) || { info "Tidak ada VPS."; return 0; }

  if (( check )); then
    printf "${W}%-14s %-10s %-10s %-11s %-6s %-6s %-6s %s${N}\n" NAME PLAN BACKEND PROCS MAC IPV4 IPV6 STATUS
    for n in "${names[@]}"; do
      vps_exists "$n" || { printf '%-14s %s\n' "$n" "MISSING (tidak ada di LXD)"; bad=$((bad + 1)); continue; }
      harden_report_one "$n" || bad=$((bad + 1))
    done
    (( bad == 0 )) && ok "Semua VPS sesuai kebijakan hardening." || warn "${bad} VPS belum sesuai. Terapkan: vpsnat harden <nama|all>"
    (( bad == 0 ))
    return
  fi

  for n in "${names[@]}"; do
    vps_exists "$n" || continue
    st=$(vps_state "$n"); [[ "$st" == RUNNING ]] && running=$((running + 1))
  done
  if (( running > 0 )) && (( $(cfg_int ANTISPOOF "$ANTISPOOF_DEFAULT") )); then
    warn "${running} VPS sedang berjalan: perubahan filter NIC bisa memutus jaringan VPS beberapa detik."
  fi
  confirm "Terapkan hardening ke ${#names[@]} VPS?" || { info "Batal."; return 0; }

  for n in "${names[@]}"; do
    if ! vps_exists "$n"; then warn "${n}: tidak ada di LXD, dilewati."; continue; fi
    plan=$(plan_type "$n"); backend=$(vps_type "$n")
    total=$((total + 1))
    if vps_harden_apply "$n" "$plan" "$backend"; then ok "${n}: hardening diterapkan."; else warn "${n}: hardening sebagian gagal."; bad=$((bad + 1)); fi
  done
  (( bad == 0 )) || { err "${bad}/${total} VPS gagal diterapkan sebagian/seluruhnya."; return 1; }
  ok "Hardening diterapkan ke ${total} VPS."
}

# ---------------------------------------------------------------------------
# Preflight ruang disk
# ---------------------------------------------------------------------------

preflight_enabled() { (( $(cfg_int PREFLIGHT "$PREFLIGHT_DEFAULT") )); }

# Bytes bebas pada filesystem yang memuat <path>; kosong bila tidak terdeteksi.
path_free_bytes() {
  local v
  v=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4 * 1024}')
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
}

storage_driver() {
  lxc query "/1.0/storage-pools/${POOL}" 2>/dev/null | jq -r '.driver // empty' 2>/dev/null
}

# Ruang bebas efektif untuk data VPS = min(sisa pool LXD, sisa filesystem host tempat loop file/pool berada).
storage_free_bytes() {
  local pool_free="" host_free="" json path
  json=$(lxc query "/1.0/storage-pools/${POOL}/resources" 2>/dev/null) || json=""
  if [[ -n "$json" ]]; then
    pool_free=$(jq -r 'if (.space.total != null and .space.used != null) then (.space.total - .space.used) else empty end' <<< "$json" 2>/dev/null)
  fi
  [[ "$pool_free" =~ ^[0-9]+$ ]] || pool_free=""
  for path in /var/snap/lxd/common/lxd /var/lib/lxd /; do
    [[ -d "$path" ]] || continue
    host_free=$(path_free_bytes "$path") || host_free=""
    break
  done
  if [[ -n "$pool_free" && -n "$host_free" ]]; then
    (( pool_free < host_free )) && printf '%s' "$pool_free" || printf '%s' "$host_free"
  elif [[ -n "$pool_free" ]]; then
    printf '%s' "$pool_free"
  elif [[ -n "$host_free" ]]; then
    printf '%s' "$host_free"
  fi
}

# preflight_space <label> <needed_bytes> [path]
# Tolak jika ruang bebas < needed*1.2 + buffer. Tanpa <path> dipakai ruang storage LXD.
# Fail-open: bila ruang bebas tidak terdeteksi, operasi dilanjutkan dengan peringatan.
preflight_space() {
  local label="$1" need="${2:-0}" path="${3:-}" buffer free required
  preflight_enabled || return 0
  [[ "$need" =~ ^[0-9]+$ ]] || need=0
  buffer=$(( $(cfg_int PREFLIGHT_BUFFER_GB "$PREFLIGHT_BUFFER_GB_DEFAULT") * 1073741824 ))
  if [[ -n "$path" ]]; then free=$(path_free_bytes "$path") || free=""; else free=$(storage_free_bytes) || free=""; fi
  if [[ ! "$free" =~ ^[0-9]+$ ]]; then
    warn "Preflight ${label}: ruang bebas tidak terdeteksi; pengecekan dilewati."
    return 0
  fi
  required=$(( need * 12 / 10 + buffer ))
  if (( free < required )); then
    err "Preflight ${label} ditolak: butuh ≥ $(bandwidth_fmt_bytes "$required") (operasi $(bandwidth_fmt_bytes "$need") ×1.2 + buffer $(bandwidth_fmt_bytes "$buffer")), tersedia $(bandwidth_fmt_bytes "$free"). Kosongkan ruang, atau set PREFLIGHT=0 di ${CONF_FILE}."
    return 1
  fi
  return 0
}

# Pemakaian disk (bytes) sebuah VPS dari LXD; fallback ke kuota disk di DB (batas atas).
vps_used_bytes() {
  local name="$1" v gb
  v=$(lxc query "/1.0/instances/${name}/state" 2>/dev/null | jq -r '.disk.root.usage // empty' 2>/dev/null)
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return 0; fi
  gb=$(db_field "$name" 6 2>/dev/null); [[ "$gb" =~ ^[0-9]+$ ]] || gb=0
  printf '%s' "$(( gb * 1073741824 ))"
}

# create: image + metadata, bukan seluruh kuota (disk di-thin-provision).
preflight_create() {
  local disk="${1:-1}" gb
  preflight_enabled || return 0
  [[ "$disk" =~ ^[0-9]+$ ]] || disk=1
  gb=$(cfg_int PREFLIGHT_CREATE_GB "$PREFLIGHT_CREATE_GB_DEFAULT")
  (( disk < gb )) && gb=$disk
  preflight_space "create" "$(( gb * 1073741824 ))"
}

# clone / snapshot: pool dir = salinan penuh, zfs/btrfs/lvm = copy-on-write.
preflight_vps_copy() {
  local name="$1" label="$2" driver need=0
  preflight_enabled || return 0
  driver=$(storage_driver)
  case "$driver" in
    zfs|btrfs|lvm|ceph) need=0 ;;
    *) need=$(vps_used_bytes "$name") ;;
  esac
  preflight_space "$label" "$need"
}

# backup ditulis ke filesystem host (bukan pool).
preflight_backup() {
  local name="$1" dir="$2"
  preflight_enabled || return 0
  preflight_space "backup" "$(vps_used_bytes "$name")" "$dir"
}

# restore-backup: tarball terkompresi mengembang saat diimpor (faktor ×2).
preflight_restore() {
  local file="$1" size
  preflight_enabled || return 0
  size=$(stat -c %s "$file" 2>/dev/null) || size=0
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  preflight_space "restore-backup" "$(( size * 2 ))"
}
