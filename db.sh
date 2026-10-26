#!/usr/bin/env bash

# DB pipe-delimited, backward compatible.
# 1 name | 2 ip | 3 ssh | 4 cpu | 5 ram | 6 disk | 7 ports | 8 pass | 9 created
# 10 vps_backend_type | 11 expires | 12 owner | 13 suspended | 14 plan_type
# 15 quota_bytes | 16 used_rx_bytes | 17 used_tx_bytes | 18 rate_mbps | 19 quota_suspended
# 20 high_since (legacy <=3.3; sejak 3.4 selalu 0, skor penalti ada di monitor/<nama>.penalty)
# 21 cpu_prev_seconds | 22 sample_epoch | 23 bw_prev_rx | 24 bw_prev_tx | 25 suspend_reason
DB_FIELDS=25

db_init() {
  ensure_runtime_dirs
  db_migrate
}

db_get() {
  awk -F'|' -v n="$1" '$1==n{print; exit}' "$DB_FILE" 2>/dev/null
}

db_field() {
  # Hot path (monitor) menyalakan cache: baca dari memori, bukan memindai file per field.
  if [[ -n "${VPSNAT_DB_CACHE_USED:-}" ]]; then
    db_field_cached "$@"
    return $?
  fi
  local line
  line=$(db_get "$1")
  [[ -z "$line" ]] && return 1
  printf '%s\n' "$line" | cut -d'|' -f"$2"
}

# Varian tanpa command substitution: db_field_var <outvar> <name> <idx>.
db_field_var() {
  local __idx="${3:-}" __out="" __line
  if [[ -n "${VPSNAT_DB_CACHE_USED:-}" ]]; then
    __line="${VPSNAT_DB_CACHE[${2:-}]:-}"
    if [[ -n "$__line" && "$__idx" =~ ^[0-9]+$ ]]; then
      local -a __f=()
      IFS='|' read -r -a __f <<< "$__line"
      (( __idx >= 1 && __idx <= ${#__f[@]} )) && __out="${__f[$((__idx - 1))]}"
    fi
  else
    __out=$(db_field "${2:-}" "$__idx")
  fi
  printf -v "$1" '%s' "$__out"
  return 0
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
      # Legacy DB rows always reserved an SSH port in column 3, even when
      # older versions left the mapping column empty. Restore that mapping.
      if (($7 == "" || $7 == "-") && $3 ~ /^[0-9]{1,5}$/ && ($3+0) >= 1 && ($3+0) <= 65535) $7="tcp:" $3 ":22"
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
  local name="$1" tmp pairs pair idx val found
  shift
  tmp=$(mktemp "${BASE_DIR}/.db.XXXXXX") || return 1
  found=$(awk -F'|' -v n="$name" '$1==n {found=1} END {print found+0}' "$DB_FILE") || { rm -f "$tmp"; return 1; }
  [[ "$found" == 1 ]] || { rm -f "$tmp"; return 1; }
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

# --- Batch read/write API (v3.4.1) ----------------------------------------------------------
# Hot path monitor memanggil db_field puluhan kali per VPS per siklus, dan setiap panggilan
# memindai SELURUH file DB (awk). Dengan N VPS biayanya O(N^2) dan di atas ~120 VPS siklus
# 15 detik tidak pernah tercapai. API di bawah memuat DB sekali (satu proses awk) dan
# menerapkan semua perubahan satu siklus dalam SATU penulisan ulang file.

# Muat seluruh DB ke associative array. Dipanggil eksplisit oleh pemanggil hot path;
# selama aktif, db_field membaca dari memori alih-alih memindai file.
declare -gA VPSNAT_DB_CACHE=()
VPSNAT_DB_CACHE_USED=""

db_cache_load() {
  local -a lines=()
  local line
  VPSNAT_DB_CACHE=()
  if [[ -s "$DB_FILE" ]]; then
    mapfile -t lines < "$DB_FILE" || return 1
    for line in "${lines[@]}"; do
      [[ -z "${line//[[:space:]]/}" ]] && continue
      VPSNAT_DB_CACHE["${line%%|*}"]="$line"
    done
  fi
  VPSNAT_DB_CACHE_USED=1
  return 0
}

db_cache_clear() {
  VPSNAT_DB_CACHE=()
  VPSNAT_DB_CACHE_USED=""
}

# Baris utuh satu VPS dari cache (satu lookup, tanpa fork).
db_row_cached() {
  printf '%s\n' "${VPSNAT_DB_CACHE[${1:-}]:-}"
}

db_field_cached() {
  local line="${VPSNAT_DB_CACHE[${1:-}]:-}" idx="${2:-}"
  [[ -n "$line" && "$idx" =~ ^[0-9]+$ ]] || return 1
  local -a f=()
  IFS='|' read -r -a f <<< "$line"
  (( idx >= 1 && idx <= ${#f[@]} )) || return 1
  printf '%s\n' "${f[$((idx - 1))]}"
}

# Baca seluruh 25 field satu VPS dalam satu pemindaian file.
# Hasil di array global DB_ROW (indeks 0 = kolom 1). Return 1 bila record tidak ada.
declare -ga DB_ROW=()
db_row() {
  local line
  if [[ -n "$VPSNAT_DB_CACHE_USED" ]]; then
    line="${VPSNAT_DB_CACHE[${1:-}]:-}"
    [[ -n "$line" ]] || return 1
  else
    line=$(db_get "${1:-}")
    [[ -n "$line" ]] || return 1
  fi
  DB_ROW=()
  IFS='|' read -r -a DB_ROW <<< "$line"
  return 0
}

# --- Akumulasi perubahan lalu tulis sekali (batch write) ---
declare -gA VPSNAT_BATCH=()
BATCH_DEFER=""

db_batch_begin() { VPSNAT_BATCH=(); }

# db_batch_set <name> "20=0" "21=..." ...
db_batch_set() {
  local name="${1:-}"
  shift || true
  [[ -n "$name" ]] || return 1
  local cur="${VPSNAT_BATCH[$name]:-}" p
  for p in "$@"; do
    [[ "$p" =~ ^[0-9]+= ]] || continue
    cur+=" $p"
  done
  VPSNAT_BATCH["$name"]="${cur# }"
  return 0
}

_db_batch_commit_locked() {
  local tmp upd name
  (( ${#VPSNAT_BATCH[@]} > 0 )) || return 0
  upd=$(mktemp "${BASE_DIR}/.dbupd.XXXXXX") || return 1
  for name in "${!VPSNAT_BATCH[@]}"; do
    printf '%s\t%s\n' "$name" "${VPSNAT_BATCH[$name]}"
  done > "$upd" || { rm -f "$upd"; return 1; }
  tmp=$(mktemp "${BASE_DIR}/.db.XXXXXX") || { rm -f "$upd"; return 1; }
  awk -F'|' -v OFS='|' -v max="$DB_FIELDS" -v updfile="$upd" '
    BEGIN { while ((getline l < updfile) > 0) { split(l, t, "\t"); if (t[1] != "") upd[t[1]] = t[2] } close(updfile) }
    {
      if ($0 ~ /^[[:space:]]*$/) next
      while (NF < max) $(NF+1)=""
      if (NF > max) NF = max
      if ($1 in upd) {
        c = split(upd[$1], p, " ")
        for (i = 1; i <= c; i++) {
          split(p[i], kv, "=")
          if (kv[1] ~ /^[0-9]+$/ && kv[1] >= 1 && kv[1] <= max) $(kv[1]) = substr(p[i], length(kv[1]) + 2)
        }
      }
      print
    }
  ' "$DB_FILE" > "$tmp" || { rm -f "$tmp" "$upd"; return 1; }
  rm -f "$upd"
  chmod 600 "$tmp"
  mv -f "$tmp" "$DB_FILE" || return 1
  VPSNAT_BATCH=()
  return 0
}

db_batch_commit() {
  (( ${#VPSNAT_BATCH[@]} > 0 )) || return 0
  with_lock _db_batch_commit_locked
}

# Penulisan saat mode defer aktif: kumpulkan ke batch, bukan tulis file per VPS.
db_metric_write() {
  if [[ -n "${BATCH_DEFER:-}" ]]; then
    db_batch_set "$@"
  else
    db_set_fields "$@"
  fi
}

# Selalu baca dari file, mengabaikan cache. Dipakai untuk verifikasi pasca-mutasi
# (mis. memastikan status suspended benar-benar tersimpan sebelum melanjutkan).
db_field_file() {
  local line
  line=$(awk -F'|' -v n="$1" '$1==n{print; exit}' "$DB_FILE" 2>/dev/null)
  [[ -z "$line" ]] && return 1
  printf '%s\n' "$line" | cut -d'|' -f"$2"
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

# Peta nama->status dari SATU panggilan LXD (v3.4.1). Hot path monitor dan `list`
# memakai ini agar tidak men-spawn `lxc info` untuk setiap VPS (O(N) subprocess).
declare -gA VPS_STATES=()
vps_states_load() {
  local n st
  VPS_STATES=()
  # Prefer muat-massal: satu panggilan LXD untuk status + metrik sekaligus.
  if lxd_bulk_load; then
    for n in "${!LXD_STATUS[@]}"; do VPS_STATES["$n"]="${LXD_STATUS[$n]}"; done
    return 0
  fi
  while IFS=, read -r n st; do
    [[ -n "$n" ]] && VPS_STATES["$n"]="${st:-}"
  done < <(lxc list --format csv -c ns 2>/dev/null)
  return 0
}

vps_state_fast() {
  local n="${1:-}"
  [[ -n "$n" ]] || return 0
  if [[ -n "${VPS_STATES[$n]+x}" ]]; then printf '%s\n' "${VPS_STATES[$n]}"; return 0; fi
  vps_state "$n"
}

# Varian tanpa command substitution untuk loop hot path.
vps_state_var() {
  local __n="${2:-}" __st=""
  if [[ -n "${VPS_STATES[$__n]+x}" ]]; then
    __st="${VPS_STATES[$__n]}"
  else
    __st=$(vps_state "$__n")
  fi
  printf -v "$1" '%s' "$__st"
}

# --- Metrik massal satu panggilan LXD (v3.4.1) ------------------------------------------------
# `lxc query /1.0/instances?recursion=2` mengembalikan state SEMUA instance (cpu.usage,
# memory.usage, status) sekaligus. Versi lama memanggil `lxc query .../state` per VPS,
# yaitu N subprocess per siklus monitor.
declare -gA LXD_CPU_NS=() LXD_MEM_BYTES=() LXD_STATUS=() LXD_CPU_LIMIT=() LXD_HOST_IF=()
LXD_BULK_LOADED=""

lxd_bulk_load() {
  local json n st cpu mem cl hif
  LXD_CPU_NS=(); LXD_MEM_BYTES=(); LXD_STATUS=(); LXD_CPU_LIMIT=(); LXD_HOST_IF=(); LXD_BULK_LOADED=""
  command -v jq >/dev/null 2>&1 || return 1
  command -v lxc >/dev/null 2>&1 || [[ -x /snap/bin/lxc ]] || return 1
  json=$(lxc query "/1.0/instances?recursion=2" 2>/dev/null) || return 1
  [[ -n "$json" ]] || return 1
  while IFS=$'\t' read -r n st cpu mem cl hif; do
    [[ -z "$n" ]] && continue
    LXD_STATUS["$n"]="${st:-}"
    LXD_CPU_NS["$n"]="${cpu:-0}"
    LXD_MEM_BYTES["$n"]="${mem:-0}"
    LXD_CPU_LIMIT["$n"]="${cl:-}"
    LXD_HOST_IF["$n"]="${hif:-}"
  done < <(jq -r '.[] | [.name, (.state.status // ""), (.state.cpu.usage // 0), (.state.memory.usage // 0), (.expanded_config["limits.cpu"] // ""), (.state.network.eth0.host_name // "")] | @tsv' <<< "$json" 2>/dev/null)
  (( ${#LXD_STATUS[@]} > 0 )) || return 1
  LXD_BULK_LOADED=1
  return 0
}

# --- Backup DB (v3.4.0) ---------------------------------------------------------------------
# db_backup_snapshot <tag> [suffix] -> cetak path backup. Rotasi per tag (DB_BACKUP_KEEP terbaru).
db_backup_snapshot() {
  local tag="${1:-manual}" suffix="${2:-}" ts base dest keep seq=0
  [[ -f "$DB_FILE" ]] || return 0
  mkdir -p "$DB_BACKUP_DIR" || return 1
  chmod 700 "$DB_BACKUP_DIR" 2>/dev/null || true
  ts=$(date +%Y%m%d-%H%M%S)
  base="${DB_BACKUP_DIR}/vps.db.${tag}${suffix:+.$suffix}.${ts}"
  dest="$base"
  while [[ -e "$dest" ]]; do seq=$((seq + 1)); dest="${base}.${seq}"; done
  # cp tanpa -p: mtime = waktu backup (dipakai urutan rotasi), bukan mtime DB.
  ( umask 077; with_lock cp "$DB_FILE" "$dest" ) || { err "Backup DB gagal ditulis ke ${dest}."; return 1; }
  chmod 600 "$dest" 2>/dev/null || true
  keep=$(cfg_int DB_BACKUP_KEEP "$DB_BACKUP_KEEP_DEFAULT")
  (( keep >= 1 )) || keep=1
  ls -1t "${DB_BACKUP_DIR}/vps.db.${tag}."* 2>/dev/null | tail -n "+$((keep + 1))" | xargs -r rm -f --
  printf '%s\n' "$dest"
}

# Jumlah record (baris non-kosong) pada file DB.
db_rows_count() { awk 'NF && $0 !~ /^[[:space:]]*$/ {n++} END {print n+0}' "$1" 2>/dev/null; }

# Valid bila tiap baris punya nama dan >= DB_FIELDS kolom (dipanggil setelah normalisasi, jadi kolom sudah dipadatkan).
db_verify_file() {
  awk -F'|' -v max="$DB_FIELDS" '
    $0 ~ /^[[:space:]]*$/ { next }
    { if ($1 == "" || NF < max) bad = 1 }
    END { exit bad ? 1 : 0 }
  ' "$1" 2>/dev/null
}

# CLI: vpsnat db-backup [list]
db_backup_cmd() {
  case "${1:-create}" in
    create) need_root; db_init; local p; p=$(db_backup_snapshot manual) || return 1; [[ -n "$p" ]] && ok "Backup DB: ${p}" ;;
    list) ls -1t "$DB_BACKUP_DIR" 2>/dev/null || echo "(belum ada backup)" ;;
    *) err "Pakai: vpsnat db-backup [create|list]"; return 1 ;;
  esac
}
