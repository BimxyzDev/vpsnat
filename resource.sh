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

resource_metrics() {
  local name="$1" json cpu_ns mem_bytes cpu_s mem_pct cpu_pct cpu_limit
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
    cpu_s=${cpu_s:-0}
    cpu_ns=$(awk -v s="$cpu_s" 'BEGIN{printf "%.0f",s*1000000000}')
  fi
  cpu_ns=${cpu_ns:-0}; mem_bytes=${mem_bytes:-0}
  cpu_s=$(awk -v n="$cpu_ns" 'BEGIN{printf "%.9f",n/1000000000}')
  cpu_limit=$(lxc config get "$name" limits.cpu 2>/dev/null)
  cpu_limit=$(resource_cpu_limit_count "${cpu_limit:-1}")
  local ram_limit
  ram_limit=$(db_field "$name" 5); ram_limit=${ram_limit:-1024}
  cpu_limit=$(( cpu_limit > 0 ? cpu_limit : 1 ))

  cpu_pct=$(awk -v cur="$cpu_s" -v prev="$(db_field "$name" 21)" -v now="$(date +%s)" -v prevts="$(db_field "$name" 22)" -v cores="$cpu_limit" 'BEGIN{
    if(prev==""||prevts==""||cur<prev||now<=prevts){print -1; exit}
    elapsed=now-prevts; pct=((cur-prev)/(elapsed*cores))*100;
    if(pct<0)pct=0; if(pct>100)pct=100; printf "%.2f",pct
  }')
  mem_pct=$(awk -v used="$mem_bytes" -v lim="$ram_limit" 'BEGIN{lim=lim*1024*1024; if(lim<=0){print 0;exit}; pct=(used/lim)*100; if(pct<0)pct=0; if(pct>100)pct=100; printf "%.2f",pct}')
  printf '%s|%s|%s\n' "$cpu_s" "${cpu_pct:--1}" "$mem_pct"
}

resource_update_one() {
  local name="$1" metrics cpu_s cpu_pct mem_pct prev_high now high threshold suspend_minutes old_reason
  metrics=$(resource_metrics "$name") || return 0
  IFS='|' read -r cpu_s cpu_pct mem_pct <<< "$metrics"
  now=$(date +%s)
  threshold=$(cfg_int SHARED_RESOURCE_THRESHOLD "$RESOURCE_THRESHOLD_DEFAULT")
  suspend_minutes=$(cfg_int SHARED_SUSPEND_MINUTES "$SHARED_SUSPEND_MINUTES_DEFAULT")
  prev_high=$(db_field "$name" 20); prev_high=${prev_high:-0}
  old_reason=$(db_field "$name" 25); old_reason=${old_reason:--}

  if [[ "$cpu_pct" != "-1" && $(awk -v x="$cpu_pct" -v t="$threshold" 'BEGIN{print (x>=t)?1:0}') == 1 || \
      $(awk -v x="$mem_pct" -v t="$threshold" 'BEGIN{print (x>=t)?1:0}') == 1 ]]; then
    if (( prev_high == 0 )); then
      db_set_fields "$name" "20=$now" "21=$cpu_s" "22=$now"
    else
      db_set_fields "$name" "21=$cpu_s" "22=$now"
      if (( now - prev_high >= suspend_minutes * 60 )); then
        _vps_suspend_auto "$name" "shared-resource"
        tg_notify "⏸ VPS ${name} otomatis disuspend: CPU/RAM mencapai ${threshold}% terus selama ${suspend_minutes} menit (CPU ${cpu_pct}%, RAM ${mem_pct}%)."
        db_set_field "$name" 20 0
      fi
    fi
  else
    db_set_fields "$name" "20=0" "21=$cpu_s" "22=$now"
    if [[ "$old_reason" == "shared-resource" ]]; then
      db_set_field "$name" 25 -
    fi
  fi
}

resource_check() {
  need_root
  local name plan state susp
  db_init
  while IFS='|' read -r name ip ssh cpu ram disk ports pass created backend exp owner susp plan quota usedrx usedtx rate quota_susp high prev_cpu prev_ts prev_rx prev_tx reason; do
    [[ -z "$name" ]] && continue
    [[ "${plan:-shared}" == "shared" ]] || continue
    [[ "${susp:-0}" == "1" ]] && continue
    [[ "$(vps_state "$name")" == "RUNNING" ]] || continue
    resource_update_one "$name"
  done < "$DB_FILE"
  bandwidth_check_all
}

monitor_loop() {
  bandwidth_sync_all || true
  need_root
  db_init
  local interval
  interval=$(cfg_int RESOURCE_SAMPLE_SECONDS "$RESOURCE_SAMPLE_SECONDS_DEFAULT")
  (( interval >= 5 )) || interval=5
  log "Resource/bandwidth monitor started; interval=${interval}s"
  while true; do
    resource_check >/dev/null 2>&1 || log "Monitor cycle failed."
    sleep "$interval"
  done
}
