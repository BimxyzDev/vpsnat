#!/usr/bin/env bash

resource_cpu_limit_count() {
  local raw="$1" part count=0
  raw=$(echo "$raw" | xargs)
  [[ -z "$raw" ]] && { echo 1; return; }
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
    return
  fi
  if [[ "$raw" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    echo $((BASH_REMATCH[2] - BASH_REMATCH[1] + 1))
    return
  fi
  if [[ "$raw" == *,* ]]; then
    tr ',' '\n' <<< "$raw" | awk 'END{print NR}'
    return
  fi
  count=$(grep -oE '[0-9]+' <<< "$raw" | head -n1)
  echo "${count:-1}"
}

# Konversi nanodetik -> detik (9 desimal) tanpa subprocess (`printf` adalah builtin).
ns_to_sec_var() {
  local __n="${2:-0}"
  if [[ ! "$__n" =~ ^[0-9]+$ ]]; then printf -v "$1" '%s' "0.000000000"; return 0; fi
  if (( ${#__n} <= 9 )); then
    printf -v "$1" '0.%09d' "$((10#$__n))"
  else
    printf -v "$1" '%s.%s' "${__n:0:${#__n}-9}" "${__n: -9}"
  fi
}

# Detik desimal -> nanodetik, ke variabel. Tanpa subprocess.
sec_to_ns_var() {
  local __s="${2:-0}" __ip __fp
  if [[ ! "$__s" =~ ^[0-9]+([.][0-9]+)?$ ]]; then printf -v "$1" '%s' 0; return 0; fi
  __ip="${__s%%.*}"
  if [[ "$__s" == *.* ]]; then __fp="${__s#*.}"; else __fp=""; fi
  __fp="${__fp}000000000"
  printf -v "$1" '%s' $(( 10#${__ip:-0} * 1000000000 + 10#${__fp:0:9} ))
}

# Hitung metrik dan simpan ke variabel pemanggil (tanpa subshell).
# resource_metrics_var <var_cpu_s> <var_cpu_pct> <var_mem_pct> <nama>
resource_metrics_var() {
  local _o_s="$1" _o_p="$2" _o_m="$3" name="$4"
  local json cpu_ns="" mem_bytes cpu_s mem_pct cpu_pct cpu_limit ram_limit
  # Jalur cepat: metrik sudah dimuat massal untuk seluruh armada (satu panggilan LXD).
  if [[ -n "${LXD_BULK_LOADED:-}" && -n "${LXD_CPU_NS[$name]+x}" ]]; then
    cpu_ns="${LXD_CPU_NS[$name]}"
    mem_bytes="${LXD_MEM_BYTES[$name]:-0}"
    cpu_limit="${LXD_CPU_LIMIT[$name]:-}"
  fi
  if [[ -z "$cpu_ns" ]]; then
    json=$(lxc query "/1.0/instances/${name}/state" 2>/dev/null || true)
    if [[ -n "$json" ]] && jq -e . >/dev/null 2>&1 <<< "$json"; then
      cpu_ns=$(jq -r '.cpu.usage // 0' <<< "$json")
      mem_bytes=$(jq -r '.memory.usage // 0' <<< "$json")
    else
      cpu_s=$(lxc info "$name" 2>/dev/null | awk -F': ' '/CPU usage \(in seconds\)/{print $2; exit}')
      mem_bytes=$(lxc info "$name" 2>/dev/null | awk '/Memory \(current\):/{print $3; exit}' | awk '
        /GiB$/ {printf "%.0f",$1*1024*1024*1024; exit}
        /MiB$/ {printf "%.0f",$1*1024*1024; exit}
        /KiB$/ {printf "%.0f",$1*1024; exit}
        /B$/ {gsub(/B/,""); printf "%.0f",$1; exit}
        {print 0}
      ')
      sec_to_ns_var cpu_ns "${cpu_s:-0}"
    fi
  fi
  cpu_ns=${cpu_ns:-0}; mem_bytes=${mem_bytes:-0}
  ns_to_sec_var cpu_s "$cpu_ns"

  if [[ -z "${cpu_limit:-}" ]]; then
    cpu_limit=$(lxc config get "$name" limits.cpu 2>/dev/null)
  fi
  cpu_limit=$(resource_cpu_limit_count "${cpu_limit:-1}")
  db_field_var ram_limit "$name" 5; ram_limit=${ram_limit:-1024}
  cpu_limit=$(( cpu_limit > 0 ? cpu_limit : 1 ))

  # CPU%: aritmetika integer (versi lama memakai `awk` per VPS).
  local prev prevts pns nowv elapsed cpu_ms denom ps
  db_field_var prev "$name" 21
  db_field_var prevts "$name" 22; prevts=${prevts:-0}
  nowv="${CYCLE_NOW:-$(date +%s)}"
  [[ "$prevts" =~ ^[0-9]+$ ]] || prevts=0
  if [[ -n "$prev" ]] && (( nowv > prevts )); then
    sec_to_ns_var pns "$prev"
    elapsed=$(( nowv - prevts ))
    if (( cpu_ns >= pns && elapsed > 0 )); then
      cpu_ms=$(( (cpu_ns - pns) / 1000000 ))
      denom=$(( elapsed * cpu_limit ))
      # Pembulatan (bukan trunkasi) agar identik dengan printf "%.2f" versi lama.
      ps=$(( (cpu_ms * 10 + denom / 2) / denom ))
      (( ps < 0 )) && ps=0
      (( ps > 10000 )) && ps=10000
      printf -v cpu_pct '%d.%02d' $(( ps / 100 )) $(( ps % 100 ))
    else
      cpu_pct=-1
    fi
  else
    cpu_pct=-1
  fi

  # RAM%: integer math dengan pembulatan, tanpa toleransi (sama seperti versi lama).
  local mscale mlim
  if (( ram_limit > 0 )); then
    mlim=$(( ram_limit * 1048576 ))
    mscale=$(( (mem_bytes * 10000 + mlim / 2) / mlim ))
    (( mscale < 0 )) && mscale=0
    (( mscale > 10000 )) && mscale=10000
    printf -v mem_pct '%d.%02d' $(( mscale / 100 )) $(( mscale % 100 ))
  else
    mem_pct="0.00"
  fi

  printf -v "$_o_s" '%s' "$cpu_s"
  printf -v "$_o_p" '%s' "${cpu_pct:--1}"
  printf -v "$_o_m" '%s' "$mem_pct"
}

# Antarmuka lama (dipakai tes & pemanggil lain): cetak "cpu_s|cpu_pct|mem_pct".
resource_metrics() {
  local _s _p _m
  resource_metrics_var _s _p _m "${1:-}"
  printf '%s|%s|%s\n' "$_s" "$_p" "$_m"
}

# --- Penalti auto-suspend shared (leaky bucket, v3.4.0) -------------------------------------------
# Skor (detik beban) naik selama sampel >= threshold dan turun PENALTY_DECAY_PERCENT% dari lama
# sampel normal. Pola "duty cycle" (mis. penuh 55 menit lalu 1 sampel idle) tidak lagi mereset hitungan
# seperti versi <=3.3. Skor disimpan per VPS di monitor/<nama>.penalty (tanpa perubahan schema DB).
penalty_file() { printf '%s/%s.penalty' "$MONITOR_DIR" "$1"; }

# Catatan hot path: seluruh helper di bawah memakai path langsung (tanpa command
# substitution) dan hanya menyentuh disk bila file memang ada.
penalty_get() {
  local v
  penalty_get_var v "${1:-}"
  printf '%s' "$v"
}

# Varian tanpa command substitution untuk hot path: hasil ke variabel pemanggil.
penalty_get_var() {
  local __f="${MONITOR_DIR}/${2}.penalty" __v=0
  [[ -r "$__f" ]] && IFS= read -r __v < "$__f" 2>/dev/null
  [[ "$__v" =~ ^[0-9]+([.][0-9]+)?$ ]] || __v=0
  printf -v "$1" '%s' "$__v"
}

penalty_set() {
  local f="${MONITOR_DIR}/${1}.penalty" tmp
  [[ -d "$MONITOR_DIR" ]] || mkdir -p "$MONITOR_DIR" 2>/dev/null || return 1
  tmp="${f}.tmp.$$"
  { printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

penalty_reset() {
  local f="${MONITOR_DIR}/${1}.penalty"
  [[ -e "$f" ]] || return 0
  rm -f "$f" 2>/dev/null || true
}

# penalty_next <skor> <dt_detik> <high 0|1> <cpu_diketahui 0|1> <decay_persen> <cap_dt_detik>
penalty_next() {
  local v
  penalty_next_var v "$@"
  printf '%s' "$v"
}

# Varian aritmetika bash (tanpa `awk`) untuk hot path. Skor dihitung dalam satuan 1/100.
penalty_next_var() {
  local __s="${2:-0}" __d="${3:-0}" __hi="${4:-0}" __ck="${5:-0}" __r="${6:-0}" __c="${7:-0}"
  local __ip __fp __sh __v
  [[ "$__s" =~ ^[0-9]+([.][0-9]+)?$ ]] || __s=0
  __ip="${__s%%.*}"
  if [[ "$__s" == *.* ]]; then __fp="${__s#*.}"; else __fp=""; fi
  __fp="${__fp}00"
  __sh=$(( 10#${__ip:-0} * 100 + 10#${__fp:0:2} ))
  [[ "$__d" =~ ^[0-9]+$ ]] || __d=0
  [[ "$__r" =~ ^[0-9]+$ ]] || __r=0
  [[ "$__c" =~ ^[0-9]+$ ]] || __c=0
  [[ "$__hi" =~ ^[0-9]+$ ]] || __hi=0
  [[ "$__ck" =~ ^[0-9]+$ ]] || __ck=0
  if (( __hi )); then
    (( __d > __c )) && __d=__c
    __v=$(( __sh + __d * 100 ))
  elif (( __ck )); then
    __v=$(( __sh - (__d * 100 * __r) / 100 ))
    (( __v < 0 )) && __v=0
  else
    __v=$__sh
  fi
  printf -v "$1" '%d.%02d' $(( __v / 100 )) $(( __v % 100 ))
}

resource_update_one() {
  local name="$1" metrics cpu_s cpu_pct mem_pct now threshold tol cpu_threshold suspend_minutes limit
  local interval cap decay prev_ts dt stored score new_score legacy old_reason high=0 cpu_known=0
  if [[ -n "${LXD_BULK_LOADED:-}" ]]; then
    # Produksi dengan muat-massal: hitung metrik tanpa subshell.
    resource_metrics_var cpu_s cpu_pct mem_pct "$name"
  else
    metrics=$(resource_metrics "$name") || return 0
    IFS='|' read -r cpu_s cpu_pct mem_pct <<< "$metrics"
  fi
  # Satu pembacaan jam per siklus (CYCLE_NOW), bukan per VPS.
  now="${CYCLE_NOW:-$(date +%s)}"
  cfg_int_var threshold SHARED_RESOURCE_THRESHOLD "$RESOURCE_THRESHOLD_DEFAULT"
  # Toleransi hanya untuk CPU: rata-rata 15 detik hampir tak pernah tepat 100% walau VPS memakai semua core.
  # RAM sengaja tanpa toleransi (usage cgroup bisa memuat page cache -> risiko suspend salah).
  cfg_int_var tol SHARED_CPU_TOLERANCE "$SHARED_CPU_TOLERANCE_DEFAULT"
  (( tol < threshold )) || tol=0
  cpu_threshold=$((threshold - tol))
  cfg_int_var suspend_minutes SHARED_SUSPEND_MINUTES "$SHARED_SUSPEND_MINUTES_DEFAULT"
  (( suspend_minutes >= 1 )) || suspend_minutes=1
  limit=$((suspend_minutes * 60))
  cfg_int_var decay PENALTY_DECAY_PERCENT "$PENALTY_DECAY_PERCENT_DEFAULT"
  cfg_int_var interval RESOURCE_SAMPLE_SECONDS "$RESOURCE_SAMPLE_SECONDS_DEFAULT"
  cap=$((interval * 4)); (( cap >= 60 )) || cap=60
  db_field_var old_reason "$name" 25; old_reason=${old_reason:--}
  db_field_var prev_ts "$name" 22; prev_ts=${prev_ts:-0}
  [[ "$prev_ts" =~ ^[0-9]+$ ]] || prev_ts=0
  dt=0; (( prev_ts > 0 && now > prev_ts )) && dt=$((now - prev_ts))

  penalty_get_var stored "$name"; score="$stored"
  # Migrasi sekali dari high_since (kolom 20 versi <=3.3): lama beban berturut-turut = skor awal.
  db_field_var legacy "$name" 20; legacy=${legacy:-0}
  if [[ ! -e "${MONITOR_DIR}/${name}.penalty" && "$legacy" =~ ^[0-9]+$ ]] && (( legacy > 1000000000 && legacy < now )); then
    score=$((now - legacy)); (( score < limit )) || score=$((limit - 1))
  fi

  [[ "$cpu_pct" != "-1" ]] && cpu_known=1
  # Perbandingan tanpa subprocess (versi lama: 3-4 `awk` per VPS per siklus).
  if (( cpu_known )) && pct_ge "$cpu_pct" "$cpu_threshold"; then high=1; fi
  if pct_ge "$mem_pct" "$threshold"; then high=1; fi
  penalty_next_var new_score "$score" "$dt" "$high" "$cpu_known" "$decay" "$cap"

  db_metric_write "$name" "20=0" "21=$cpu_s" "22=$now" || true

  if (( high )) && pct_ge "$new_score" "$limit"; then
    # Flush dulu: apply_all_rules membaca DB dari file, jadi status suspended harus sudah tersimpan.
    db_batch_commit || true
    _vps_suspend_auto "$name" "shared-resource" || true   # rc != 0 juga untuk kegagalan parsial; status sebenarnya dibaca dari DB
    if [[ "$(db_field_file "$name" 13)" == "1" ]]; then
      penalty_reset "$name"
      db_cache_load || true
      tg_notify "⏸ VPS ${name} otomatis disuspend: CPU/RAM ≥ ${threshold}% (CPU ≥ ${cpu_threshold}%) terakumulasi ${suspend_minutes} menit (CPU ${cpu_pct}%, RAM ${mem_pct}%)."
      return 0
    fi
    log "Auto-suspend ${name} belum berhasil (lock/DB); dicoba lagi pada siklus berikutnya."
  fi

  if [[ "$new_score" =~ [1-9] ]]; then
    penalty_set "$name" "$new_score" || true
  else
    penalty_reset "$name"
  fi
  if (( ! high )) && [[ "$old_reason" == "shared-resource" ]]; then
    db_metric_write "$name" "25=-"
  fi
}

resource_check() {
  need_root
  local name plan state susp _st
  db_init
  # Satu pemuatan DB + satu penulisan per siklus (v3.4.1). Sebelumnya tiap VPS memicu
  # ~8 pemindaian file dan 1 penulisan ulang penuh, sehingga biaya siklus O(N^2).
  db_cache_load || true
  vps_states_load || true
  conf_cache_load
  CYCLE_NOW=$(date +%s)
  BATCH_DEFER=1
  db_batch_begin
  while IFS='|' read -r name ip ssh cpu ram disk ports pass created backend exp owner susp plan quota usedrx usedtx rate quota_susp high prev_cpu prev_ts prev_rx prev_tx reason; do
    [[ -z "$name" ]] && continue
    [[ "${plan:-shared}" == "shared" ]] || continue
    [[ "${susp:-0}" == "1" ]] && continue
    vps_state_var _st "$name"
    [[ "$_st" == "RUNNING" ]] || continue
    resource_update_one "$name"
  done < "$DB_FILE"
  db_batch_commit || log "Batch commit siklus resource gagal."
  BATCH_DEFER=""
  db_cache_clear
  conf_cache_clear
  bandwidth_check_all
}

monitor_loop() {
  bandwidth_sync_all || true
  need_root
  db_init
  local interval
  interval=$(cfg_int RESOURCE_SAMPLE_SECONDS "$RESOURCE_SAMPLE_SECONDS_DEFAULT")
  (( interval >= 5 )) || interval=5
  # Monitor tidak boleh menunggu lock alokasi berjam-jam di belakang create/clone/reinstall yang panjang;
  # auto-suspend yang gagal karena lock otomatis dicoba lagi pada siklus berikutnya.
  export VPSNAT_ALLOC_LOCK_TIMEOUT
  VPSNAT_ALLOC_LOCK_TIMEOUT=$(cfg_int MONITOR_LOCK_TIMEOUT "$MONITOR_LOCK_TIMEOUT_DEFAULT")
  log "Resource/bandwidth monitor started; interval=${interval}s lock-timeout=${VPSNAT_ALLOC_LOCK_TIMEOUT}s"
  while true; do
    resource_check >/dev/null 2>&1 || log "Monitor cycle failed."
    sleep "$interval"
  done
}
