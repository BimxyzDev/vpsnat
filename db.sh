#!/usr/bin/env bash

# DB pipe-delimited, backward compatible.
# 1 name | 2 ip | 3 ssh | 4 cpu | 5 ram | 6 disk | 7 ports | 8 pass | 9 created
# 10 vps_backend_type | 11 expires | 12 owner | 13 suspended | 14 plan_type
# 15 quota_bytes | 16 used_rx_bytes | 17 used_tx_bytes | 18 rate_mbps | 19 quota_suspended
# 20 high_since | 21 cpu_prev_seconds | 22 sample_epoch | 23 bw_prev_rx | 24 bw_prev_tx
DB_FIELDS=25

db_init() {
  ensure_runtime_dirs
  db_migrate
}

db_get() {
  awk -F'|' -v n="$1" '$1==n{print; exit}' "$DB_FILE" 2>/dev/null
}

db_field() {
  local line
  line=$(db_get "$1")
  [[ -z "$line" ]] && return 1
  printf '%s\n' "$line" | cut -d'|' -f"$2"
}

db_normalize_file() {
  local src tmp
  src="$DB_FILE"
  tmp=$(mktemp "${BASE_DIR}/.db.XXXXXX") || return 1
  awk -F'|' -v OFS='|' -v max="$DB_FIELDS" '
    {
      if ($0 ~ /^[[:space:]]*$/) next
      while (NF < max) $(NF+1)=""
      if (NF > max) { NF=max }
      if ($10 == "") $10="container"
      if ($11 == "") $11=0
      if ($12 == "") $12="-"
      if ($13 == "") $13=0
      if ($14 == "") $14="shared"
      if ($15 == "") $15=0
      # Versions before 3.1 could persist quota as GB during create.
      if ($15 ~ /^[0-9]+([.][0-9]+)?$/ && $15 > 0 && $15 < 1000000) $15=sprintf("%.0f", $15*1000000000)
      if ($16 == "") $16=0
      if ($17 == "") $17=0
      if ($18 == "") $18=0
      if ($19 == "") $19=0
      if ($20 == "") $20=0
      if ($21 == "") $21=0
      if ($22 == "") $22=0
      if ($23 == "") $23=0
      if ($24 == "") $24=0
      if ($25 == "") $25="-"
      print
    }
  ' "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$src"
}

db_migrate() {
  with_lock db_normalize_file
}

_db_add() {
  local line
  line="${1}|${2}|${3}|${4}|${5}|${6}|${7}|${8}|${9}|${10:-container}|${11:-0}|${12:--}|${13:-0}|${14:-shared}|${15:-0}|0|0|${16:-0}|0|0|0|0|0|0|-"
  printf '%s\n' "$line" >> "$DB_FILE"
}
db_add() { with_lock _db_add "$@"; }

_db_del() {
  local tmp
  tmp=$(mktemp "${BASE_DIR}/.db.XXXXXX") || return 1
  awk -F'|' -v n="$1" '$1!=n' "$DB_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$DB_FILE"
}
db_del() { with_lock _db_del "$1"; }

_db_set_field() {
  local name="$1" idx="$2" val="$3" tmp
  [[ "$idx" =~ ^[0-9]+$ ]] || return 1
  (( idx >= 1 && idx <= DB_FIELDS )) || return 1
  [[ -n "$(db_get "$name")" ]] || return 1
  tmp=$(mktemp "${BASE_DIR}/.db.XXXXXX") || return 1
  VAL="$val" awk -F'|' -v OFS='|' -v n="$name" -v i="$idx" -v max="$DB_FIELDS" '
    { while (NF < max) $(NF+1)=""; if ($1==n) $i=ENVIRON["VAL"]; print }
  ' "$DB_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$DB_FILE"
}
db_set_field() { with_lock _db_set_field "$@"; }

# Explicit helper for the monitor/bandwidth hot path; values are passed as index:value pairs.
db_set_fields() {
  local name="$1"; shift
  [[ -n "$(db_get "$name")" ]] || return 1
  with_lock _db_set_fields_locked "$name" "$@"
}

_db_set_fields_locked() {
  local name="$1" tmp pairs pair idx val
  shift
  tmp=$(mktemp "${BASE_DIR}/.db.XXXXXX") || return 1
  awk -F'|' -v OFS='|' -v n="$name" -v max="$DB_FIELDS" -v pairs="$*" '
    BEGIN {
      count=split(pairs,a," ");
      for(i=1;i<=count;i++){
        split(a[i],b,"=");
        if (b[1] ~ /^[0-9]+$/ && b[1] >= 1 && b[1] <= max) v[b[1]]=substr(a[i], length(b[1])+2)
      }
    }
    { while (NF < max) $(NF+1)=""; if ($1==n) for(k in v) $(k)=v[k]; print }
  ' "$DB_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$DB_FILE"
}

vps_type() {
  local t
  t=$(db_field "$1" 10)
  echo "${t:-container}"
}

plan_type() {
  local t
  t=$(db_field "$1" 14)
  echo "${t:-shared}"
}

vps_exists() { lxc info "$1" &>/dev/null; }

vps_state() { lxc info "$1" 2>/dev/null | awk '/^Status:/{print $2}'; }
