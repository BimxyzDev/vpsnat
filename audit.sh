#!/usr/bin/env bash

# Audit trail append-only (v3.4.1).
#
# Setiap mutasi administratif dicatat sebagai satu baris JSON di AUDIT_FILE. Format JSON
# dipilih agar mudah dikonsumsi tool lain (jq, SIEM, export CSV) tanpa parser khusus.
#
# Prinsip:
#   * append-only + satu baris per kejadian (tidak pernah menulis ulang file);
#   * kegagalan menulis audit TIDAK pernah menggagalkan operasi bisnis (best-effort),
#     tetapi selalu tercatat di log utama sebagai peringatan;
#   * nilai rahasia tidak pernah masuk audit (password, token, private key).

AUDIT_FILE="${AUDIT_FILE:-${BASE_DIR}/audit.log}"
AUDIT_MAX_BYTES_DEFAULT=10485760   # 10 MiB; rotasi satu generasi (.1)

audit_enabled() { [[ "$(cfg_int AUDIT_LOG "$AUDIT_LOG_DEFAULT")" != "0" ]]; }

# audit_log <actor> <action> <target> <result> [detail]
# actor : "cli:root", "bot:<user_id>", "web:admin", "web:user:<nama>", "system:monitor"
audit_log() {
  local actor="${1:--}" action="${2:--}" target="${3:--}" result="${4:--}" detail="${5:-}"
  audit_enabled || return 0
  mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null || return 0
  local ts max
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  max=$(cfg_int AUDIT_MAX_BYTES "$AUDIT_MAX_BYTES_DEFAULT")
  # Rotasi sederhana: satu generasi. Dilakukan sebelum tulis agar file aktif tak tumbuh tanpa batas.
  if [[ -f "$AUDIT_FILE" ]]; then
    local size
    size=$(stat -c %s "$AUDIT_FILE" 2>/dev/null || echo 0)
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > max )); then
      mv -f "$AUDIT_FILE" "${AUDIT_FILE}.1" 2>/dev/null || true
    fi
  fi
  # JSON dirakit dengan printf + escape minimal (kutip, backslash, newline).
  local a="${actor//\\/\\\\}"; a="${a//\"/\\\"}"; a="${a//$'\n'/ }"
  local c="${action//\\/\\\\}"; c="${c//\"/\\\"}"; c="${c//$'\n'/ }"
  local t="${target//\\/\\\\}"; t="${t//\"/\\\"}"; t="${t//$'\n'/ }"
  local r="${result//\\/\\\\}"; r="${r//\"/\\\"}"; r="${r//$'\n'/ }"
  local d="${detail//\\/\\\\}"; d="${d//\"/\\\"}"; d="${d//$'\n'/ }"
  printf '{"ts":"%s","actor":"%s","action":"%s","target":"%s","result":"%s","detail":"%s"}\n' \
    "$ts" "$a" "$c" "$t" "$r" "$d" >> "$AUDIT_FILE" 2>/dev/null \
    || { log "WARN: gagal menulis audit (${action} ${target})"; return 0; }
  chmod 600 "$AUDIT_FILE" 2>/dev/null || true
  return 0
}

# Aktor untuk proses CLI interaktif (dipanggil dari cli.sh).
audit_actor_cli() {
  local who="${SUDO_USER:-${USER:-root}}"
  printf 'cli:%s' "${who:-root}"
}

audit_tail() {
  local n="${1:-40}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=40
  [[ -f "$AUDIT_FILE" ]] || { echo "(belum ada audit log)"; return 0; }
  tail -n "$n" "$AUDIT_FILE"
}

audit_search() {
  local q="${1:-}"
  [[ -f "$AUDIT_FILE" ]] || { echo "(belum ada audit log)"; return 0; }
  if [[ -z "$q" ]]; then
    audit_tail "${2:-40}"
  else
    grep -F -- "$q" "$AUDIT_FILE" | tail -n "${2:-40}"
  fi
}

audit_cmd() {
  case "${1:-tail}" in
    tail|"") shift || true; audit_tail "${1:-40}" ;;
    search|grep) shift || true; audit_search "${1:-}" "${2:-40}" ;;
    path) echo "$AUDIT_FILE" ;;
    *) err "Pakai: vpsnat audit [tail [N]|search <kata> [N]|path]"; return 1 ;;
  esac
}
