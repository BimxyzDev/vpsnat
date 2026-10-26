#!/usr/bin/env bash

settings_show() {
  echo -e "${W}=== VPSNAT Settings ===${N}"
  printf 'GRACE_DAYS                 = %s\n' "$(cfg_int GRACE_DAYS "$GRACE_DAYS_DEFAULT")"
  printf 'SHARED_SUSPEND_MINUTES    = %s\n' "$(cfg_int SHARED_SUSPEND_MINUTES "$SHARED_SUSPEND_MINUTES_DEFAULT")"
  printf 'SHARED_RESOURCE_THRESHOLD = %s%%\n' "$(cfg_int SHARED_RESOURCE_THRESHOLD "$RESOURCE_THRESHOLD_DEFAULT")"
  printf 'RESOURCE_SAMPLE_SECONDS   = %s\n' "$(cfg_int RESOURCE_SAMPLE_SECONDS "$RESOURCE_SAMPLE_SECONDS_DEFAULT")"
  printf 'BANDWIDTH_DEFAULT_QUOTA_GB = %s\n' "$(conf_get BANDWIDTH_DEFAULT_QUOTA_GB || echo 0)"
  printf 'BANDWIDTH_DEFAULT_RATE_MBIT = %s\n' "$(conf_get BANDWIDTH_DEFAULT_RATE_MBIT || echo 0)"
  printf 'NETWORK_MODE               = %s\n' "$(conf_get NETWORK_MODE || echo direct)"
  printf 'SHARED_CPU_TOLERANCE      = %s%%\n' "$(cfg_int SHARED_CPU_TOLERANCE "$SHARED_CPU_TOLERANCE_DEFAULT")"
  printf 'PROC_LIMIT_SHARED         = %s\n' "$(cfg_int PROC_LIMIT_SHARED "$PROC_LIMIT_SHARED_DEFAULT")"
  printf 'PROC_LIMIT_DEDICATED      = %s\n' "$(cfg_int PROC_LIMIT_DEDICATED "$PROC_LIMIT_DEDICATED_DEFAULT")"
  printf 'CONN_LIMIT                = %s\n' "$(cfg_int CONN_LIMIT "$CONN_LIMIT_DEFAULT")"
  printf 'SMTP_BLOCK                = %s\n' "$(cfg_int SMTP_BLOCK "$SMTP_BLOCK_DEFAULT")"
}

settings_set() {
  need_root
  local key="${1:-}" value="${2:-}"
  [[ -n "$key" && -n "$value" ]] || { err "Pakai: vpsnat settings set <key> <value>"; return 1; }

  case "${key,,}" in
    grace|grace_days)
      [[ "$value" =~ ^[0-9]+$ ]] && ((value <= 3650)) || { err "GRACE_DAYS harus 0-3650."; return 1; }
      conf_set GRACE_DAYS "$value" ;;
    shared-suspend|shared-suspend-minutes|shared_suspend_minutes|suspend-minutes)
      [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 10080)) || { err "SHARED_SUSPEND_MINUTES harus 1-10080."; return 1; }
      conf_set SHARED_SUSPEND_MINUTES "$value" ;;
    shared-threshold|shared_resource_threshold|resource-threshold)
      [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 100)) || { err "SHARED_RESOURCE_THRESHOLD harus 1-100."; return 1; }
      conf_set SHARED_RESOURCE_THRESHOLD "$value" ;;
    monitor-interval|resource_sample_seconds|sample-seconds)
      [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 5 && value <= 3600)) || { err "RESOURCE_SAMPLE_SECONDS harus 5-3600."; return 1; }
      conf_set RESOURCE_SAMPLE_SECONDS "$value"
      systemctl try-restart "${MONITOR_SERVICE}.service" >/dev/null 2>&1 || true ;;
    bandwidth-default-quota|bandwidth_default_quota_gb)
      [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "BANDWIDTH_DEFAULT_QUOTA_GB harus angka >= 0."; return 1; }
      conf_set BANDWIDTH_DEFAULT_QUOTA_GB "$value" ;;
    bandwidth-default-rate|bandwidth_default_rate_mbit)
      bandwidth_rate_normalize "$value" >/dev/null || { err "BANDWIDTH_DEFAULT_RATE_MBIT harus angka Mbps >= 0."; return 1; }
      conf_set BANDWIDTH_DEFAULT_RATE_MBIT "$value" ;;
    shared-cpu-tolerance|shared_cpu_tolerance)
      [[ "$value" =~ ^[0-9]+$ ]] && ((value <= 50)) || { err "SHARED_CPU_TOLERANCE harus 0-50."; return 1; }
      conf_set SHARED_CPU_TOLERANCE "$value" ;;
    proc-limit-shared|proc_limit_shared)
      [[ "$value" =~ ^[0-9]+$ ]] && (( value == 0 || (value >= 16 && value <= 4194304) )) || { err "PROC_LIMIT_SHARED harus 0 (tanpa batas) atau 16-4194304."; return 1; }
      conf_set PROC_LIMIT_SHARED "$value"
      info "Berlaku untuk VPS baru / set-type. VPS lama: vpsnat harden all" ;;
    proc-limit-dedicated|proc_limit_dedicated)
      [[ "$value" =~ ^[0-9]+$ ]] && (( value == 0 || (value >= 16 && value <= 4194304) )) || { err "PROC_LIMIT_DEDICATED harus 0 (tanpa batas) atau 16-4194304."; return 1; }
      conf_set PROC_LIMIT_DEDICATED "$value"
      info "Berlaku untuk VPS baru / set-type. VPS lama: vpsnat harden all" ;;
    conn-limit|conn_limit)
      [[ "$value" =~ ^[0-9]+$ ]] && (( value == 0 || (value >= 16 && value <= 1000000) )) || { err "CONN_LIMIT harus 0 (nonaktif) atau 16-1000000."; return 1; }
      conf_set CONN_LIMIT "$value"
      apply_all_rules || warn "Setting tersimpan, tetapi firewall belum diterapkan; jalankan: vpsnat restore" ;;
    smtp-block|smtp_block)
      [[ "$value" =~ ^[01]$ ]] || { err "SMTP_BLOCK harus 0 atau 1."; return 1; }
      conf_set SMTP_BLOCK "$value"
      apply_all_rules || warn "Setting tersimpan, tetapi firewall belum diterapkan; jalankan: vpsnat restore" ;;
    *)
      err "Setting tidak dikenal: $key"; return 1 ;;
  esac
  audit_log "$(audit_actor_cli)" "settings.set" "${key}" "ok" "value=${value}"
  ok "${key} = ${value}"
}

settings_cmd() {
  case "${1:-show}" in
    show) settings_show ;;
    set) shift; settings_set "$@" ;;
    *) err "Pakai: vpsnat settings [show|set]"; return 1 ;;
  esac
}
