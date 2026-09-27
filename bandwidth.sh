#!/usr/bin/env bash

bandwidth_unit_bytes() { echo 1000000000; }

bandwidth_host_iface() {
  local name="$1" iface
  iface=$(lxc config device get "$name" eth0 host_name 2>/dev/null || true)
  if [[ -n "$iface" && -e "/sys/class/net/$iface" ]]; then
    echo "$iface"
    return 0
  fi
  lxc info "$name" 2>/dev/null | awk '/Host interface:/{print $3; exit}'
}

bandwidth_counters() {
  local iface="$1" rx tx
  [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" ]] || return 1
  rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null) || return 1
  tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null) || return 1
  [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$rx" "$tx"
}

bandwidth_rate_normalize() {
  local rate="$1"
  [[ -z "$rate" || "$rate" == "0" ]] && { echo 0; return 0; }
  [[ "$rate" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v r="$rate" 'BEGIN{ if (r <= 0) exit 1; printf "%.3f\n", r }'
}

bandwidth_apply_tc() {
  need_root
  local name="$1" rate iface
  rate=$(db_field "$name" 18)
  rate=${rate:-0}
  iface=$(bandwidth_host_iface "$name")
  [[ -z "$iface" ]] && { warn "Interface veth/tap untuk ${name} belum tersedia."; return 1; }
  command -v tc >/dev/null 2>&1 || { err "tc tidak tersedia. Install iproute2."; return 1; }

  tc filter del dev "$iface" ingress pref 49150 2>/dev/null || true
  if [[ "$rate" == "0" ]]; then
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc del dev "$iface" clsact 2>/dev/null || true
    return 0
  fi

  if ! tc qdisc replace dev "$iface" root handle 100: tbf rate "${rate}mbit" burst 256kb latency 50ms; then
    err "Gagal memasang egress bandwidth limit ${rate} Mbps pada ${name} (${iface})."
    return 1
  fi
  tc qdisc add dev "$iface" clsact 2>/dev/null || true
  tc filter del dev "$iface" ingress pref 49150 2>/dev/null || true
  tc filter add dev "$iface" ingress pref 49150 protocol all u32 match u32 0 0 police rate "${rate}mbit" burst 256kb conform-exceed drop
}

bandwidth_sync_all() {
  local name rate
  while IFS='|' read -r name _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ rate _; do
    [[ -z "$name" ]] && continue
    rate=${rate:-0}
    bandwidth_apply_tc "$name" >/dev/null 2>&1 || true
  done < "$DB_FILE"
}

bandwidth_used_bytes() {
  local n="$1" rx tx
  rx=$(db_field "$n" 16); tx=$(db_field "$n" 17)
  rx=${rx:-0}; tx=${tx:-0}
  echo $((rx + tx))
}

bandwidth_fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1000000000000) printf "%.2f TB", b/1000000000000;
    else if (b >= 1000000000) printf "%.2f GB", b/1000000000;
    else if (b >= 1000000) printf "%.2f MB", b/1000000;
    else if (b >= 1000) printf "%.2f KB", b/1000;
    else printf "%d B", b;
  }'
}

bandwidth_status() {
  local n="$1" quota rx tx used rate qstate
  quota=$(db_field "$n" 15); quota=${quota:-0}
  rx=$(db_field "$n" 16); rx=${rx:-0}
  tx=$(db_field "$n" 17); tx=${tx:-0}
  rate=$(db_field "$n" 18); rate=${rate:-0}
  qstate=$(db_field "$n" 19); qstate=${qstate:-0}
  used=$((rx + tx))
  if (( quota > 0 )); then
    awk -v u="$used" -v q="$quota" 'BEGIN{printf "Kuota    : %.2f / %.2f GB (%.1f%%)\n", u/1000000000, q, (u/q)*100}'
  else
    echo "Kuota    : unlimited"
  fi
  echo "RX       : $(bandwidth_fmt_bytes "$rx")"
  echo "TX       : $(bandwidth_fmt_bytes "$tx")"
  echo "Rate     : ${rate} Mbps"
  (( qstate == 1 )) && echo "Quota    : EXHAUSTED (network blocked)" || echo "Quota    : ACTIVE"
}

bandwidth_set() {
  need_root
  local n="$1" quota="$2" rate="$3" quota_bytes normalized
  n=$(pick_vps "$n") || return 1
  quota=${quota:-0}; rate=${rate:-0}
  [[ "$quota" =~ ^([0-9]+([.][0-9]+)?)$ ]] || { err "Kuota harus angka GB; 0 = unlimited."; return 1; }
  normalized=$(bandwidth_rate_normalize "$rate") || { err "Rate harus angka Mbps; 0 = unlimited."; return 1; }
  quota_bytes=$(awk -v g="$quota" 'BEGIN{printf "%.0f", g*1000000000}')
  db_set_fields "$n" "15=$quota_bytes" "18=$normalized"
  bandwidth_apply_tc "$n" || return 1
  if (( quota_bytes == 0 )); then
    db_set_field "$n" 19 0
  else
    local used; used=$(bandwidth_used_bytes "$n")
    if (( used >= quota_bytes )); then db_set_field "$n" 19 1; else db_set_field "$n" 19 0; fi
  fi
  apply_all_rules
  ok "Bandwidth ${n}: quota ${quota} GB, limit ${normalized} Mbps."
}

bandwidth_reset() {
  need_root
  local n="$1" iface counters rx tx
  n=$(pick_vps "$n") || return 1
  iface=$(bandwidth_host_iface "$n") || true
  if [[ -n "$iface" ]]; then
    counters=$(bandwidth_counters "$iface" 2>/dev/null || true)
    read -r rx tx <<< "${counters:-0 0}"
  else
    rx=0; tx=0
  fi
  db_set_fields "$n" "16=0" "17=0" "19=0" "23=${rx:-0}" "24=${tx:-0}"
  apply_all_rules
  ok "Kuota bandwidth ${n} di-reset."
}

bandwidth_update_usage() {
  local name="$1" iface counters rx tx prev_rx prev_tx delta_rx delta_tx old_exhausted quota used was_exhausted=0
  iface=$(bandwidth_host_iface "$name")
  [[ -z "$iface" ]] && return 0
  counters=$(bandwidth_counters "$iface" 2>/dev/null || true)
  [[ -z "$counters" ]] && return 0
  read -r rx tx <<< "$counters"
  prev_rx=$(db_field "$name" 23); prev_tx=$(db_field "$name" 24)
  prev_rx=${prev_rx:-0}; prev_tx=${prev_tx:-0}

  if (( rx < prev_rx )); then prev_rx=0; fi
  if (( tx < prev_tx )); then prev_tx=0; fi
  delta_rx=$((rx - prev_rx)); delta_tx=$((tx - prev_tx))

  db_set_fields "$name" \
    "16=$(( $(db_field "$name" 16) + delta_rx ))" \
    "17=$(( $(db_field "$name" 17) + delta_tx ))" \
    "23=$rx" "24=$tx"

  quota=$(db_field "$name" 15); quota=${quota:-0}
  old_exhausted=$(db_field "$name" 19); old_exhausted=${old_exhausted:-0}
  used=$(bandwidth_used_bytes "$name")
  if (( quota > 0 && used >= quota )); then
    db_set_field "$name" 19 1
    (( old_exhausted == 1 )) || { apply_all_rules; tg_notify "🚫 VPS ${name} mencapai kuota bandwidth ($(bandwidth_fmt_bytes "$used")) dan network diblokir. Reset: vpsnat bandwidth ${name} reset"; }
  elif (( quota == 0 || used < quota )) && (( old_exhausted == 1 )); then
    db_set_field "$name" 19 0
    apply_all_rules
  fi
}

vps_bandwidth() {
  need_root
  local n="$1" action="${2:-show}"
  n=$(pick_vps "$n") || return 1
  case "$action" in
    show|status)
      echo -e "${W}=== Bandwidth ${n} ===${N}"
      bandwidth_status "$n"
      ;;
    set)
      local quota="${3:-${BW_QUOTA_GB:-${QUOTA:-}}}" rate="${4:-${BW_LIMIT_MBIT:-${BW_RATE_MBIT:-${RATE:-}}}}"
      if [[ -z "$quota" && "$NONINTERACTIVE" != "1" ]]; then read -rp "Kuota GB [0=unlimited]: " quota; fi
      if [[ -z "$rate" && "$NONINTERACTIVE" != "1" ]]; then read -rp "Limit Mbps [0=unlimited]: " rate; fi
      bandwidth_set "$n" "${quota:-0}" "${rate:-0}"
      ;;
    reset)
      bandwidth_reset "$n"
      ;;
    limit)
      local rate="${3:-${BW_LIMIT_MBIT:-${BW_RATE_MBIT:-${RATE:-}}}}"
      [[ -z "$rate" && "$NONINTERACTIVE" != "1" ]] && read -rp "Limit Mbps [0=unlimited]: " rate
      local cur_quota; cur_quota=$(db_field "$n" 15); cur_quota=${cur_quota:-0}
      bandwidth_set "$n" "$(awk -v b="$cur_quota" 'BEGIN{printf "%.9f",b/1000000000}')" "${rate:-0}"
      ;;
    *)
      err "Aksi bandwidth: show|set|reset|limit"
      return 1
      ;;
  esac
}

bandwidth_check_all() {
  local name ip ssh cpu ram disk ports pass created backend exp owner susp plan quota rx tx rate qstate high prevcpu prevts prevrx prevtx reason
  while IFS='|' read -r name ip ssh cpu ram disk ports pass created backend exp owner susp plan quota rx tx rate qstate high prevcpu prevts prevrx prevtx reason; do
    [[ -z "$name" ]] && continue
    [[ "${plan:-shared}" == "shared" || "${plan:-shared}" == "dedicated" ]] || continue
    [[ "$(vps_state "$name")" == "RUNNING" ]] || continue
    bandwidth_update_usage "$name"
  done < "$DB_FILE"
}
