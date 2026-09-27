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
    *)
      err "Setting tidak dikenal: $key"; return 1 ;;
  esac
  ok "${key} = ${value}"
}

settings_cmd() {
  case "${1:-show}" in
    show) settings_show ;;
    set) shift; settings_set "$@" ;;
    *) err "Pakai: vpsnat settings [show|set]"; return 1 ;;
  esac
}
