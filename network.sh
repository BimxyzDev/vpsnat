#!/usr/bin/env bash

# Run port kosong pada [SSH_BASE..PORT_MAX], satu "awal akhir" per baris. Satu kali baca DB + ss
# (versi lama memanggil awk+ss untuk SETIAP port => puluhan ribu fork per alokasi).
port_free_runs() {
  {
    [[ -s "$DB_FILE" ]] && awk -F'|' '
      $3 ~ /^[0-9]+$/ { print $3 + 0 }
      { n = split($7, e, ","); for (i = 1; i <= n; i++) { split(e[i], a, ":"); if (a[2] ~ /^[0-9]+$/) print a[2] + 0 } }
    ' "$DB_FILE" 2>/dev/null
    ss -H -lntu 2>/dev/null | awk '{a = $5; sub(/^.*:/, "", a); if (a ~ /^[0-9]+$/) print a + 0}'
  } | awk -v lo="$SSH_BASE" -v hi="$PORT_MAX" '
    { used[$1 + 0] = 1 }
    END {
      run = 0
      for (p = lo; p <= hi; p++) {
        if (p in used) { if (run) { print start, p - 1; run = 0 } }
        else if (!run) { start = p; run = 1 }
      }
      if (run) print start, hi
    }'
}

# Satu blok kontigu pertama (first-fit) yang muat <need> port: "awal akhir".
alloc_contiguous_ports() {
  local need="$1" s e
  [[ "$need" =~ ^[0-9]+$ ]] || return 1
  (( need >= 1 )) || return 1
  while read -r s e; do
    [[ -n "$s" ]] || continue
    if (( e - s + 1 >= need )); then
      echo "${s} $((s + need - 1))"
      return 0
    fi
  done < <(port_free_runs)
  return 1
}

# Alokasi multi-blok (greedy best-fit) saat tidak ada satu blok kontigu yang cukup:
# ambil run terbesar penuh, blok terakhir memakai run terkecil yang masih muat.
# Keluaran satu port per baris (urut blok naik). Gagal bila butuh lebih dari <max_chunks> blok.
alloc_port_chunks() {
  local need="$1" max_chunks="${2:-$PORT_SPLIT_MAX_CHUNKS_DEFAULT}"
  [[ "$need" =~ ^[0-9]+$ && "$max_chunks" =~ ^[0-9]+$ ]] || return 1
  (( need >= 1 && max_chunks >= 1 )) || return 1
  port_free_runs | awk -v need="$need" -v maxc="$max_chunks" '
    { n++; s[n] = $1; l[n] = $2 - $1 + 1; used[n] = 0 }
    END {
      rem = need; k = 0
      while (rem > 0 && k < maxc) {
        best = 0; big = 0
        for (i = 1; i <= n; i++) {
          if (used[i]) continue
          if (l[i] >= rem && (best == 0 || l[i] < l[best])) best = i
          if (big == 0 || l[i] > l[big]) big = i
        }
        if (best) { take = rem; pick = best } else if (big) { take = l[big]; pick = big } else break
        used[pick] = 1; k++; cs[k] = s[pick]; cl[k] = take; rem -= take
      }
      if (rem > 0) exit 1
      for (i = 2; i <= k; i++) {
        ts = cs[i]; tl = cl[i]; j = i - 1
        while (j >= 1 && cs[j] > ts) { cs[j + 1] = cs[j]; cl[j + 1] = cl[j]; j-- }
        cs[j + 1] = ts; cl[j + 1] = tl
      }
      for (i = 1; i <= k; i++) for (p = 0; p < cl[i]; p++) print cs[i] + p
    }'
}

# Kontigu bila bisa; kalau tidak, pecah ke maksimal PORT_SPLIT_MAX_CHUNKS blok.
# Keluaran: satu port per baris.
alloc_ports() {
  local need="$1" range start end chunks
  if range=$(alloc_contiguous_ports "$need"); then
    read -r start end <<< "$range"
    seq "$start" "$end"
    return 0
  fi
  chunks=$(cfg_int PORT_SPLIT_MAX_CHUNKS "$PORT_SPLIT_MAX_CHUNKS_DEFAULT")
  (( chunks > 1 )) || return 1
  alloc_port_chunks "$need" "$chunks"
}

# Ringkas daftar port menjadi rentang: 20010 20011 20012 30000 -> 20010-20012,30000
port_ranges_label() {
  printf '%s\n' "$@" | awk '
    NR == 1 { s = p = $1; next }
    $1 == p + 1 { p = $1; next }
    { printf "%s%s", (o++ ? "," : ""), (s == p ? s : s "-" p); s = p = $1 }
    END { printf "%s%s\n", (o++ ? "," : ""), (s == p ? s : s "-" p) }'
}

next_ip() {
  # Satu pass awk + lookup array; versi lama menjalankan `grep` untuk setiap kandidat
  # (sampai 249 fork per alokasi).
  local i cand
  local -A used=()
  while IFS= read -r i; do
    [[ -n "$i" ]] && used["$i"]=1
  done < <(awk -F'|' 'NF && $2 != "" { print $2 }' "$DB_FILE" 2>/dev/null)
  for i in $(seq 2 250); do
    cand="${NET_PREFIX}.${i}"
    [[ -n "${used[$cand]:-}" ]] || { echo "$cand"; return 0; }
  done
  return 1
}

port_used() {
  local p="$1"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )) || return 0
  # Legacy rows can reserve SSH in column 3 while column 7 is empty or '-'.
  if awk -F'|' -v p="$((10#$p))" '
    $3 ~ /^[0-9]+$/ && ($3+0)==p { found=1 }
    {
      n=split($7, entries, ",")
      for (i=1; i<=n; i++) {
        split(entries[i], a, ":")
        if (a[2] ~ /^[0-9]+$/ && (a[2]+0)==p) found=1
      }
    }
    END { exit !found }
  ' "$DB_FILE" 2>/dev/null; then
    return 0
  fi
  ss -H -lntu 2>/dev/null | awk -v p="$((10#$p))" '{a=$5; sub(/^.*:/,"",a); if(a==p) found=1} END{exit !found}'
}

ensure_net() {
  export PATH="$PATH:/snap/bin"
  local dns="dhcp-option=6,1.1.1.1,8.8.8.8"
  lxc network show "$BRIDGE" &>/dev/null || return 0
  [[ "$(lxc network get "$BRIDGE" ipv4.dhcp 2>/dev/null)" == "true" ]] || lxc network set "$BRIDGE" ipv4.dhcp true
  [[ "$(lxc network get "$BRIDGE" raw.dnsmasq 2>/dev/null)" == "$dns" ]] || lxc network set "$BRIDGE" raw.dnsmasq "$dns"
  lxc profile device unset "$PROFILE" root size &>/dev/null || true
}

init_lxd() {
  export PATH="$PATH:/snap/bin"
  if lxc network show "$BRIDGE" &>/dev/null && lxc storage show "$POOL" &>/dev/null; then
    ensure_net
    ok "LXD sudah terinisialisasi."
    return 0
  fi

  local pool_size driver
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    pool_size="${STORAGE_SIZE_GB:-50}"
  else
    read -rp "Ukuran storage pool total untuk semua VPS (GB) [50]: " pool_size
    pool_size=${pool_size:-50}
  fi
  [[ "$pool_size" =~ ^[0-9]+$ ]] || die "Ukuran storage harus angka."

  driver="dir"
  if command -v zpool &>/dev/null && modprobe zfs 2>/dev/null; then
    driver="zfs"
  elif command -v btrfs &>/dev/null && grep -qw btrfs /proc/filesystems; then
    driver="btrfs"
  fi
  info "Storage driver: ${driver}"
  conf_set STORAGE_DRIVER "$driver"

  if ! lxc storage show "$POOL" &>/dev/null; then
    case "$driver" in
      dir) lxc storage create "$POOL" dir || die "Gagal buat storage." ;;
      *)   lxc storage create "$POOL" "$driver" size="${pool_size}GB" || {
             warn "Driver ${driver} gagal, fallback ke dir."
             lxc storage create "$POOL" dir || die "Gagal buat storage."
             conf_set STORAGE_DRIVER dir
           } ;;
    esac
  fi

  if ! lxc network show "$BRIDGE" &>/dev/null; then
    lxc network create "$BRIDGE" \
      ipv4.address="$SUBNET" \
      ipv4.nat=false \
      ipv4.dhcp=true \
      ipv6.address=none \
      dns.mode=managed || die "Gagal buat bridge."
  fi

  lxc profile show "$PROFILE" &>/dev/null || lxc profile create "$PROFILE"
  lxc profile device remove "$PROFILE" root &>/dev/null || true
  lxc profile device remove "$PROFILE" eth0 &>/dev/null || true
  lxc profile device add "$PROFILE" root disk path=/ pool="$POOL"
  lxc profile device add "$PROFILE" eth0 nic network="$BRIDGE" name=eth0
  ensure_net
  ok "LXD siap."
}

# Always use xtables' own lock in addition to VPSNAT's cross-process lock.
ipt() { command iptables -w 10 "$@"; }

ipv4_valid() {
  local value="$1" oct
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local -a parts
  IFS=. read -r -a parts <<< "$value"
  ((${#parts[@]} == 4)) || return 1
  for oct in "${parts[@]}"; do
    [[ "$oct" =~ ^[0-9]{1,3}$ ]] && (( 10#$oct <= 255 )) || return 1
  done
}

port_valid() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

_fw_setup_locked() {
  local iface
  iface=$(detect_iface)
  [[ -z "$iface" ]] && { err "Interface publik tidak terdeteksi."; return 1; }

  ipt -t nat -N VPSNAT_PRE 2>/dev/null || ipt -t nat -S VPSNAT_PRE >/dev/null 2>&1 || { err "Gagal membuat chain VPSNAT_PRE."; return 1; }
  ipt -t nat -N VPSNAT_POST 2>/dev/null || ipt -t nat -S VPSNAT_POST >/dev/null 2>&1 || { err "Gagal membuat chain VPSNAT_POST."; return 1; }
  ipt -N VPSNAT_FWD 2>/dev/null || ipt -S VPSNAT_FWD >/dev/null 2>&1 || { err "Gagal membuat chain VPSNAT_FWD."; return 1; }

  ipt -t nat -C PREROUTING -j VPSNAT_PRE 2>/dev/null || ipt -t nat -A PREROUTING -j VPSNAT_PRE || return 1
  ipt -t nat -C OUTPUT -j VPSNAT_PRE 2>/dev/null || ipt -t nat -A OUTPUT -j VPSNAT_PRE || return 1
  ipt -t nat -C POSTROUTING -j VPSNAT_POST 2>/dev/null || ipt -t nat -A POSTROUTING -j VPSNAT_POST || return 1
  ipt -C FORWARD -j VPSNAT_FWD 2>/dev/null || ipt -I FORWARD 1 -j VPSNAT_FWD || return 1

  ipt -t nat -C VPSNAT_POST -s "${NET_PREFIX}.0/24" ! -d "${NET_PREFIX}.0/24" -o "$iface" -j MASQUERADE 2>/dev/null || \
    ipt -t nat -A VPSNAT_POST -s "${NET_PREFIX}.0/24" ! -d "${NET_PREFIX}.0/24" -o "$iface" -j MASQUERADE || return 1
  ipt -t nat -C VPSNAT_POST -s "${NET_PREFIX}.0/24" -d "${NET_PREFIX}.0/24" -j MASQUERADE 2>/dev/null || \
    ipt -t nat -A VPSNAT_POST -s "${NET_PREFIX}.0/24" -d "${NET_PREFIX}.0/24" -j MASQUERADE || return 1
}

fw_setup() { with_fw_lock _fw_setup_locked; }

fw_save() {
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || { err "Gagal menyimpan rule firewall secara persisten."; return 1; }
  else
    mkdir -p /etc/iptables || return 1
    iptables-save > /etc/iptables/rules.v4 || { err "Gagal menulis /etc/iptables/rules.v4."; return 1; }
  fi
}

_fw_validate_proto() { [[ "${1:-}" == tcp || "${1:-}" == udp || "${1:-}" == both ]]; }

_fw_add_to_chains() {
  local pre="$1" fwd="$2" proto="$3" ext="$4" ip="$5" int="$6" p
  _fw_validate_proto "$proto" && port_valid "$ext" && port_valid "$int" && ipv4_valid "$ip" || {
    err "Mapping firewall tidak valid (proto=$proto port=$ext ip=$ip internal=$int)."; return 1;
  }
  local -a protos=("$proto")
  [[ "$proto" == both ]] && protos=(tcp udp)
  for p in "${protos[@]}"; do
    ipt -t nat -C "$pre" -p "$p" --dport "$ext" -j DNAT --to-destination "${ip}:${int}" 2>/dev/null || \
      ipt -t nat -A "$pre" -p "$p" --dport "$ext" -j DNAT --to-destination "${ip}:${int}" || return 1
    ipt -C "$fwd" -p "$p" -d "$ip" --dport "$int" -j ACCEPT 2>/dev/null || \
      ipt -A "$fwd" -p "$p" -d "$ip" --dport "$int" -j ACCEPT || return 1
  done
}

_fw_target() {
  local table="$1" parent="$2"
  ipt -t "$table" -S "$parent" 2>/dev/null | awk -v c="$parent" '$1=="-A" && $2==c && $3=="-j" && ($4==c"_A" || $4==c"_B") {print $4; exit}'
}

_fw_switch() {
  local table="$1" parent="$2" target="$3" prev="$4"
  if [[ -n "$prev" ]]; then
    ipt -t "$table" -R "$parent" 1 -j "$target"
  else
    ipt -t "$table" -I "$parent" 1 -j "$target"
  fi
}

_fw_rollback_switch() {
  local table="$1" parent="$2" prev="$3"
  if [[ -n "$prev" ]]; then
    ipt -t "$table" -R "$parent" 1 -j "$prev"
  else
    ipt -t "$table" -D "$parent" 1
  fi
}

_fw_trim_dispatcher() {
  local table="$1" chain="$2" count
  # After dispatcher activation, remove stale legacy rules below it. Each iptables
  # operation is checked; if cleanup fails, a subsequent restore can retry safely.
  while :; do
    count=$(ipt -t "$table" -S "$chain" 2>/dev/null | awk -v c="$chain" '$1=="-A" && $2==c {n++} END {print n+0}') || return 1
    (( count > 1 )) || break
    ipt -t "$table" -D "$chain" 2 || return 1
  done
}

_fw_chain_ready() {
  local table="$1" chain="$2"
  ipt -t "$table" -N "$chain" 2>/dev/null || ipt -t "$table" -S "$chain" >/dev/null 2>&1
}

# Probe dukungan modul iptables pada kernel ini (rule uji dipasang lalu dihapus di chain staging).
_fw_match_supported() {
  local chain="$1"; shift
  ipt -A "$chain" "$@" -j RETURN >/dev/null 2>&1 || return 1
  ipt -D "$chain" "$@" -j RETURN >/dev/null 2>&1 || true
  return 0
}

# Guard per-VPS (v3.4.0), dievaluasi SETELAH ESTABLISHED,RELATED sehingga hanya koneksi baru yang diperiksa:
#   * blokir SMTP outbound (default 25,465,587) -> cegah VPS jadi sumber spam
#   * batasi koneksi baru concurrent per VPS (conntrack) -> satu VPS tak bisa menghabiskan tabel conntrack host
# Modul kernel yang tidak ada (xt_connlimit / xt_multiport) hanya melewati guard terkait, tidak menggagalkan firewall.
_fw_guard_rules() {
  local stage="$1" climit="$2" sblock="$3" sports="$4" ip do_conn=0 do_smtp=0
  shift 4
  (( $# > 0 )) || return 0
  if (( climit > 0 )); then
    if _fw_match_supported "$stage" -m connlimit --connlimit-above 1 --connlimit-mask 32; then
      do_conn=1
    else
      warn "Kernel tanpa xt_connlimit: batas koneksi per VPS dilewati."
    fi
  fi
  if (( sblock )) && [[ -n "$sports" ]]; then
    if _fw_match_supported "$stage" -p tcp -m multiport --dports "$sports"; then
      do_smtp=1
    else
      warn "Kernel tanpa xt_multiport: blokir SMTP outbound dilewati."
    fi
  fi
  for ip in "$@"; do
    if (( do_smtp )); then
      ipt -A "$stage" -s "$ip" -p tcp -m multiport --dports "$sports" -j REJECT --reject-with tcp-reset || return 1
    fi
    if (( do_conn )); then
      ipt -A "$stage" -s "$ip" -m conntrack --ctstate NEW -m connlimit --connlimit-above "$climit" --connlimit-mask 32 -j REJECT || return 1
    fi
  done
}

_fw_build_rules_locked() {
  local pre_stage="$1" fwd_stage="$2"
  local name ip ssh cpu ram disk ports pass created backend expires owner suspended plan quota rx tx rate quota_susp high_since cpu_prev sample_ts bw_prev_rx bw_prev_tx reason
  local e proto rest ext int p key
  local -a entries
  local -A seen_public=()
  local conn_limit smtp_block smtp_ports
  local -a guard_ips=()
  conn_limit=$(cfg_int CONN_LIMIT "$CONN_LIMIT_DEFAULT")
  smtp_block=$(cfg_int SMTP_BLOCK "$SMTP_BLOCK_DEFAULT")
  smtp_ports=$(conf_get SMTP_BLOCK_PORTS); smtp_ports="${smtp_ports:-$SMTP_BLOCK_PORTS_DEFAULT}"
  [[ "$smtp_ports" =~ ^[0-9]{1,5}(,[0-9]{1,5}){0,14}$ ]] || smtp_ports="$SMTP_BLOCK_PORTS_DEFAULT"

  _fw_chain_ready nat "$pre_stage" || { err "Gagal menyiapkan staging chain $pre_stage."; return 1; }
  _fw_chain_ready filter "$fwd_stage" || { err "Gagal menyiapkan staging chain $fwd_stage."; return 1; }
  ipt -t nat -F "$pre_stage" || return 1
  ipt -F "$fwd_stage" || return 1

  while IFS='|' read -r name ip ssh cpu ram disk ports pass created backend expires owner suspended plan quota rx tx rate quota_susp high_since cpu_prev sample_ts bw_prev_rx bw_prev_tx reason; do
    [[ -z "$name" && -z "$ip" ]] && continue
    [[ -z "$name" || -z "$ip" ]] && { err "Record DB malformed; firewall lama dipertahankan."; return 1; }
    ipv4_valid "$ip" || { err "IP tidak valid di DB untuk ${name}; firewall lama dipertahankan."; return 1; }
    if [[ "${suspended:-0}" != 1 && "${quota_susp:-0}" == 1 ]]; then
      ipt -A "$fwd_stage" -s "$ip" -j DROP || return 1
      ipt -A "$fwd_stage" -d "$ip" -j DROP || return 1
    fi
    local active=1
    [[ "${suspended:-0}" == 1 || "${quota_susp:-0}" == 1 ]] && active=0
    (( active )) && guard_ips+=("$ip")
    [[ -z "$ports" || "$ports" == "-" ]] && continue
    IFS=',' read -r -a entries <<< "$ports"
    for e in "${entries[@]}"; do
      [[ -z "$e" ]] && { err "Mapping port kosong di record ${name}; firewall lama dipertahankan."; return 1; }
      proto=${e%%:*}; rest=${e#*:}
      [[ "$rest" != "$e" && "$rest" == *:* ]] || { err "Mapping port rusak di record ${name}; firewall lama dipertahankan."; return 1; }
      ext=${rest%%:*}; int=${rest#*:}
      [[ "$int" != *:* ]] || { err "Mapping port rusak di record ${name}; firewall lama dipertahankan."; return 1; }
      [[ "$proto" == tcp || "$proto" == udp ]] && port_valid "$ext" && port_valid "$int" || {
        err "Protokol/port tidak valid pada ${name} (${e}); firewall lama dipertahankan."; return 1;
      }
      key="${proto}:${ext}"
      if [[ -n "${seen_public[$key]+x}" ]]; then
        err "Port publik ${key} bentrok antara ${seen_public[$key]} dan ${name}; firewall lama dipertahankan."
        return 1
      fi
      seen_public["$key"]="${name}(${ip}:${int})"
      if (( active )); then
        _fw_add_to_chains "$pre_stage" "$fwd_stage" "$proto" "$ext" "$ip" "$int" || {
          err "Gagal menyiapkan forwarding ${name} ${e}; firewall lama dipertahankan."; return 1;
        }
      fi
    done
  done < "$DB_FILE"

  ipt -A "$fwd_stage" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  _fw_guard_rules "$fwd_stage" "$conn_limit" "$smtp_block" "$smtp_ports" "${guard_ips[@]}" || {
    err "Gagal menyiapkan guard SMTP/conn-limit; firewall lama dipertahankan."; return 1
  }
  ipt -A "$fwd_stage" -i "$BRIDGE" -j ACCEPT || return 1
  ipt -A "$fwd_stage" -o "$BRIDGE" -j ACCEPT || return 1
}

_apply_all_rules_locked() {
  local previous_pre previous_fwd pre_stage fwd_stage
  _fw_setup_locked || { err "Firewall setup gagal; chain aktif tidak diganti."; return 1; }
  previous_pre=$(_fw_target nat VPSNAT_PRE)
  previous_fwd=$(_fw_target filter VPSNAT_FWD)
  if [[ "$previous_pre" == VPSNAT_PRE_A ]]; then pre_stage=VPSNAT_PRE_B; else pre_stage=VPSNAT_PRE_A; fi
  if [[ "$previous_fwd" == VPSNAT_FWD_A ]]; then fwd_stage=VPSNAT_FWD_B; else fwd_stage=VPSNAT_FWD_A; fi
  _fw_build_rules_locked "$pre_stage" "$fwd_stage" || return 1

  # Stage first, then atomically switch each stable chain's single dispatcher rule.
  # Keep the old chain content until both switches succeeded so rollback is possible.
  _fw_switch filter VPSNAT_FWD "$fwd_stage" "$previous_fwd" || { err "Gagal mengaktifkan staging filter chain."; return 1; }
  if ! _fw_switch nat VPSNAT_PRE "$pre_stage" "$previous_pre"; then
    _fw_rollback_switch filter VPSNAT_FWD "$previous_fwd" || err "GAGAL rollback dispatcher firewall filter."
    err "Gagal mengaktifkan staging NAT chain."; return 1
  fi
  if ! _fw_trim_dispatcher nat VPSNAT_PRE || ! _fw_trim_dispatcher filter VPSNAT_FWD; then
    err "Rule baru aktif tetapi pembersihan rule lama gagal; jalankan vpsnat restore setelah memeriksa firewall."
    return 1
  fi
  fw_save || { err "Rule aktif, tetapi penyimpanan persistence gagal."; return 1; }
}

apply_all_rules() { with_fw_lock _apply_all_rules_locked; }

# Compatibility helpers for old integrations. Internal code should update DB then call apply_all_rules.
_fw_add_forward_locked() {
  local proto="$1" ext="$2" ip="$3" int="$4" pre fwd
  pre=$(_fw_target nat VPSNAT_PRE); fwd=$(_fw_target filter VPSNAT_FWD)
  pre=${pre:-VPSNAT_PRE}; fwd=${fwd:-VPSNAT_FWD}
  _fw_add_to_chains "$pre" "$fwd" "$proto" "$ext" "$ip" "$int"
}
fw_add_forward() { with_fw_lock _fw_add_forward_locked "$@"; }

_fw_del_forward_locked() {
  local proto="$1" ext="$2" ip="$3" int="$4" pre fwd p
  _fw_validate_proto "$proto" && port_valid "$ext" && port_valid "$int" && ipv4_valid "$ip" || return 1
  pre=$(_fw_target nat VPSNAT_PRE); fwd=$(_fw_target filter VPSNAT_FWD)
  pre=${pre:-VPSNAT_PRE}; fwd=${fwd:-VPSNAT_FWD}
  local -a protos=("$proto"); [[ "$proto" == both ]] && protos=(tcp udp)
  for p in "${protos[@]}"; do
    ipt -t nat -D "$pre" -p "$p" --dport "$ext" -j DNAT --to-destination "${ip}:${int}" 2>/dev/null || true
    ipt -D "$fwd" -p "$p" -d "$ip" --dport "$int" -j ACCEPT 2>/dev/null || true
  done
}
fw_del_forward() { with_fw_lock _fw_del_forward_locked "$@"; }

set_static_ip() {
  local name="$1" ip="$2" out
  out=$(lxc config device override "$name" eth0 ipv4.address="$ip" 2>&1) && return 0
  lxc config device set "$name" eth0 ipv4.address "$ip" 2>/dev/null && return 0
  warn "Gagal set IP ${ip}: ${out}"
  return 1
}

next_ssh_port() {
  # Versi lama memindai SSH_BASE..PORT_MAX dan memanggil `port_used` (awk seluruh DB +
  # `ss -lntu`) untuk SETIAP port: hingga puluhan ribu subprocess per alokasi.
  # port_free_runs sudah memuat DB+ss sekali dan mengembalikan rentang port kosong.
  local s e
  while read -r s e; do
    [[ -n "$s" ]] || continue
    echo "$s"
    return 0
  done < <(port_free_runs)
  return 1
}

image_for() {
  case "$1" in
    ubuntu22|u22) echo "ubuntu:22.04" ;;
    ubuntu24|u24) echo "ubuntu:24.04" ;;
    ubuntu20|u20) echo "ubuntu:20.04" ;;
    debian12|d12) echo "images:debian/12" ;;
    debian11|d11) echo "images:debian/11" ;;
    alma9|a9)     echo "images:almalinux/9" ;;
    rocky9|r9)    echo "images:rockylinux/9" ;;
    alpine|alp)   echo "images:alpine/3.19" ;;
    *)            echo "$1" ;;
  esac
}

gen_pass() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16
}

wait_ip() {
  local name="$1" ip="$2" i
  for i in $(seq 1 60); do
    lxc list "$name" -c 4 --format csv 2>/dev/null | grep -q "$ip" && return 0
    sleep 2
  done
  warn "Guest belum dapat IP ${ip}."
  return 1
}

wait_guest() {
  local name="$1" i
  for i in $(seq 1 60); do
    lxc exec "$name" -- true &>/dev/null && return 0
    sleep 2
  done
  return 1
}

setup_guest() {
  local name="$1" pass="$2" i
  info "Setup guest (SSH, root password)..."
  wait_guest "$name" || warn "Guest belum responsif, lanjut."
  for i in $(seq 1 30); do
    lxc exec "$name" -- ping -c1 -W1 1.1.1.1 &>/dev/null && break
    sleep 1
  done
  lxc exec "$name" -- sh -c '
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1
      apt-get install -y openssh-server curl wget nano sudo ca-certificates >/dev/null 2>&1
      systemctl enable ssh >/dev/null 2>&1; systemctl restart ssh >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y openssh-server curl wget nano sudo >/dev/null 2>&1
      systemctl enable --now sshd >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache openssh curl wget nano sudo bash >/dev/null 2>&1
      rc-update add sshd default >/dev/null 2>&1; rc-service sshd restart >/dev/null 2>&1
    fi
  '
  printf 'root:%s\n' "$pass" | lxc exec "$name" -- chpasswd
  lxc exec "$name" -- sh -c '
    f=/etc/ssh/sshd_config
    [ -f "$f" ] || exit 0
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" "$f"
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" "$f"
    [ -d /etc/ssh/sshd_config.d ] && rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || rc-service sshd restart 2>/dev/null
  '
}
