#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for f in "$ROOT/vpsnat" "$ROOT"/*.sh; do
  bash -n "$f"
done
python3 -m py_compile "$ROOT/bot.py" "$ROOT/web.py" "$ROOT/test_web.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export VPSNAT_BASE_DIR="$tmp/etc/vpsnat"
export VPSNAT_LOG_FILE="$tmp/vpsnat.log"
export VPSNAT_APP_DIR="$ROOT"

# shellcheck source=/dev/null
source "$ROOT/core.sh"
source "$ROOT/db.sh"
source "$ROOT/network.sh"
source "$ROOT/relay.sh"
source "$ROOT/ports.sh"
source "$ROOT/bandwidth.sh"
source "$ROOT/vps.sh"
source "$ROOT/expire.sh"
source "$ROOT/resource.sh"
source "$ROOT/data.sh"
source "$ROOT/nodes.sh"
source "$ROOT/web.sh"
source "$ROOT/install.sh"
source "$ROOT/update.sh"
source "$ROOT/settings.sh"
source "$ROOT/cli.sh"

db_init
printf 'legacy|10.10.10.2|20000|1|1024|10|-|pass|2026-01-01|container|0|-|0\n' > "$DB_FILE"
db_init
[[ "$(db_field legacy 14)" == "shared" ]]
[[ "$(db_field legacy 7)" == "tcp:20000:22" ]]
! db_set_fields missing-record '13=1'
db_set_fields legacy '15=500000000000' '18=100'
printf 'legacyquota|10.10.10.3|20010|1|1024|10|-|pass|2026-01-01|container|0|-|0|shared|500|0|0|100|0|0|0|0|0|0|-
' >> "$DB_FILE"
db_init
[[ "$(db_field legacyquota 15)" == "500000000000" ]]
[[ "$(db_field legacy 15)" == "500000000000" ]]
[[ "$(db_field legacy 18)" == "100" ]]

range=$(alloc_contiguous_ports 3)
read -r a b <<< "$range"
[[ "$((b-a+1))" -eq 3 ]]

# regresi: create harus memakai SEMUA port hasil alloc_ports (dulu `read -a` hanya membaca baris pertama
# sehingga hanya port SSH yang terbuka) dan batas port saat create = 50
mapfile -t _alloc <<< "$(alloc_ports 7)"
[[ "${#_alloc[@]}" -eq 7 ]]
grep -q 'mapfile -t alloc' "$ROOT/vps.sh"
! grep -q 'read -ra alloc' "$ROOT/vps.sh"
grep -q 'requested_nports="${2:-}"' "$ROOT/vps.sh"
grep -q 'persisted_ports != nports' "$ROOT/vps.sh"
grep -Fq 'str(env["NPORTS"])' "$ROOT/web.py"
[[ "$VPS_PORTS_MIN" -eq 2 && "$VPS_PORTS_MAX" -eq 50 ]]
[[ "$(vpsnat_read_version "$ROOT/core.sh")" == "$VERSION" ]]
safe_password 'Passw0rd!23'
! safe_password 'contains space 123'
! safe_password $'line\nbreak123'
! safe_password 'short1'
! safe_password "$(printf 'a%.0s' {1..100})"
grep -q 'api.github.com/repos/' "$ROOT/update.sh"
grep -q 'vnd.github.sha' "$ROOT/get.sh"
bash "$ROOT/get.sh" --help | grep -q '^Usage: get.sh'
! bash "$ROOT/get.sh" --bukan-opsi >/dev/null 2>&1
grep -q 'with_alloc_lock _vps_create_locked' "$ROOT/vps.sh"
grep -q 'with_alloc_lock _port_add_locked' "$ROOT/ports.sh"
grep -q 'with_alloc_lock _vps_sync_locked' "$ROOT/data.sh"
grep -q 'Gagal mengubah disk; database tidak diubah.' "$ROOT/vps.sh"
! grep -q 'device unset.*root size' "$ROOT/vps.sh"

# Legacy SSH column must reserve port even when field 7 is '-'.
port_used 20000
range=$(alloc_contiguous_ports 3)
read -r a b <<< "$range"
! (( 20000 >= a && 20000 <= b ))
# Malformed/oversized expiry inputs must be rejected, never overflow into past epoch.
! parse_duration 0d >/dev/null 2>&1
! parse_duration 999999999999d >/dev/null 2>&1
! parse_duration 2026-99-99 >/dev/null 2>&1
! parse_duration 9999-12-31 >/dev/null 2>&1
! parse_duration 0000-01-01 >/dev/null 2>&1

bandwidth_rate_normalize 100 >/dev/null
grep -q 'BW_QUOTA_GB:-.*QUOTA:-' "$ROOT/bandwidth.sh"
grep -q 'BW_LIMIT_MBIT:-.*RATE:-' "$ROOT/bandwidth.sh"
grep -q '\["bandwidth", name, "set", quota, rate\]' "$ROOT/bot.py"
grep -q 'relay_dispatch' "$ROOT/cli.sh"
[[ -f "$ROOT/relay.sh" ]]

pick_vps() { echo "$1"; }
bandwidth_set() { TEST_QUOTA="$2"; TEST_RATE="$3"; }
export NONINTERACTIVE=1 QUOTA=321 RATE=77
vps_bandwidth legacy set
[[ "$TEST_QUOTA" == "321" && "$TEST_RATE" == "77" ]]

# Regresi: perpanjangan tidak boleh membuka suspension manual.
printf 'manual|10.10.10.4|20012|1|1024|10|tcp:20012:22|pass|2026-01-01|container|0|-|1|shared|0|0|0|0|0|0|0|0|0|0|manual\n' >> "$DB_FILE"
need_root() { :; }  # test terisolasi; tidak mengubah host/LXD.
bandwidth_reset() { :; }
vps_renew manual 30d >/dev/null
[[ "$(db_field manual 13)" == "1" ]]
[[ "$(db_field manual 25)" == "manual" ]]

# Integration regression: execute the real vps_create() path with a mocked LXD,
# then verify the requested number of unique ports was persisted end-to-end.
(
  export MOCK_LXC_STATE="$tmp/lxc-state" MOCK_LXC_NAMEFILE="$tmp/lxc-name" MOCK_LXC_SIZEFILE="$tmp/lxc-size" MOCK_LXC_IP="10.10.10.240"
  export NAME=integration5 IMG_KEY=ubuntu22 CPU=2 RAM=2048 DISK=15 PASS='SafePass123!' NESTING=n EXPIRE=0 OWNER=qa PLAN_TYPE=shared BW_QUOTA_GB=0 BW_LIMIT_MBIT=0
  rm -f "$MOCK_LXC_STATE" "$MOCK_LXC_NAMEFILE" "$MOCK_LXC_SIZEFILE"
  need_root() { :; }
  vm_supported() { return 1; }
  wait_guest() { return 0; }
  wait_ip() { return 0; }
  setup_guest() { return 0; }
  set_static_ip() { return 0; }
  bandwidth_apply_tc() { return 0; }
  apply_all_rules() { return 0; }
  vps_info() { return 0; }
  lxc() {
    case "${1:-}" in
      info)
        [[ -f "$MOCK_LXC_STATE" && -f "$MOCK_LXC_NAMEFILE" && "$(cat "$MOCK_LXC_NAMEFILE")" == "${2:-}" ]] || return 1
        echo 'Status: Running'; return 0 ;;
      init)
        printf '%s\n' "${3:?missing guest name}" > "$MOCK_LXC_NAMEFILE"
        : > "$MOCK_LXC_STATE"; return 0 ;;
      config)
        if [[ "${2:-}" == device && "${3:-}" == override && "${5:-}" == root && "${6:-}" == size=* ]]; then
          [[ "${MOCK_FAIL_DISK:-0}" != 1 ]] || return 1
          printf '%s\n' "${6#size=}" > "$MOCK_LXC_SIZEFILE"; return 0
        elif [[ "${2:-}" == device && "${3:-}" == set && "${5:-}" == root && "${6:-}" == size ]]; then
          [[ "${MOCK_FAIL_DISK:-0}" != 1 ]] || return 1
          printf '%s\n' "${7:-}" > "$MOCK_LXC_SIZEFILE"; return 0
        elif [[ "${2:-}" == device && "${3:-}" == get && "${5:-}" == root && "${6:-}" == size ]]; then
          [[ -r "$MOCK_LXC_SIZEFILE" ]] || return 1; cat "$MOCK_LXC_SIZEFILE"; return 0
        fi
        return 0 ;;
      list) printf '%s\n' "$MOCK_LXC_IP"; return 0 ;;
      start|stop|exec) return 0 ;;
      delete) rm -f "$MOCK_LXC_STATE" "$MOCK_LXC_NAMEFILE" "$MOCK_LXC_SIZEFILE"; return 0 ;;
      *) return 0 ;;
    esac
  }
  vps_create integration5 5 >/dev/null
  [[ "$(db_field integration5 7 | awk -F, '{for(i=1;i<=NF;i++){if(split($i,a,":")==3) seen[a[2]]=1}} END{for(p in seen)n++; print n+0}')" -eq 5 ]]
  [[ "$(cat "$MOCK_LXC_SIZEFILE")" == '15GB' ]]
) || { echo 'FAIL: mocked create did not persist all 5 ports with disk limit.' >&2; exit 1; }

# A disk-configuration failure must abort create, remove the guest, and never
# leave a successful DB record claiming that a VPS was created.
(
  export MOCK_LXC_STATE="$tmp/lxc-fail-state" MOCK_LXC_NAMEFILE="$tmp/lxc-fail-name" MOCK_LXC_SIZEFILE="$tmp/lxc-fail-size" MOCK_LXC_IP="10.10.10.241" MOCK_FAIL_DISK=1
  export NAME=integrationdisk IMG_KEY=ubuntu22 CPU=2 RAM=2048 DISK=15 PASS='SafePass123!' NESTING=n EXPIRE=0 OWNER=qa PLAN_TYPE=shared BW_QUOTA_GB=0 BW_LIMIT_MBIT=0
  rm -f "$MOCK_LXC_STATE" "$MOCK_LXC_NAMEFILE" "$MOCK_LXC_SIZEFILE"
  need_root() { :; }; vm_supported() { return 1; }; wait_guest() { return 0; }; wait_ip() { return 0; }; setup_guest() { return 0; }; set_static_ip() { return 0; }; bandwidth_apply_tc() { return 0; }; apply_all_rules() { return 0; }; vps_info() { return 0; }
  lxc() {
    case "${1:-}" in
      info) [[ -f "$MOCK_LXC_STATE" && "$(cat "$MOCK_LXC_NAMEFILE")" == "${2:-}" ]] || return 1; return 0 ;;
      init) printf '%s\n' "$3" > "$MOCK_LXC_NAMEFILE"; : > "$MOCK_LXC_STATE"; return 0 ;;
      config) if [[ "${2:-}" == device && ( "${3:-}" == override || "${3:-}" == set ) ]]; then return 1; fi; return 0 ;;
      delete) rm -f "$MOCK_LXC_STATE" "$MOCK_LXC_NAMEFILE" "$MOCK_LXC_SIZEFILE"; return 0 ;;
      *) return 0 ;;
    esac
  }
  if vps_create integrationdisk 5 >/dev/null 2>&1; then exit 1; fi
  [[ ! -s "$MOCK_LXC_STATE" && -z "$(db_get integrationdisk)" ]]
) || { echo 'FAIL: disk-configuration failure left an active guest/DB record.' >&2; exit 1; }

resource_cpu_limit_count '0-3' | grep -qx 4
parse_duration 30d >/dev/null

VPSNAT_NONINTERACTIVE=1 settings_set shared-suspend-minutes 60 >/dev/null
[[ "$(conf_get SHARED_SUSPEND_MINUTES)" == "60" ]]

# nodes.sh: registry & brief summary format harus tetap 10 kolom pipe-delimited
nodes_init
node_add localtest 10.250.0.9 22 root >/dev/null 2>&1 || true
brief=$(host_summary_brief)
[[ "$(echo "$brief" | awk -F'|' '{print NF}')" -eq 10 ]]
grep -q "^nodes_dispatch" "$ROOT/nodes.sh"

# web panel: validator domain, hash password, smoke test API
web_domain_valid panel.example.com
web_domain_valid sub.panel.example.co.id
! web_domain_valid 'bad domain'
! web_domain_valid 'a_b.example.com'
! web_domain_valid 'localhost'
! web_domain_valid '-x.example.com'
[[ "$(printf 'secret123' | python3 "$ROOT/web.py" hashpw)" == scrypt:* ]]
grep -q 'cpu="${CPU:-}"; ask cpu' "$ROOT/vps.sh"
python3 "$ROOT/test_web.py" >/dev/null

# The firewall builder must reject duplicate public protocol/port reservations
# before switching active chains; cover even rows currently marked suspended.
printf 'dupeA|10.10.10.10|21000|1|1024|10|tcp:22000:22|pass|2026-10-12|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-\n' >> "$DB_FILE"
printf 'dupeB|10.10.10.11|21001|1|1024|10|tcp:22000:22|pass|2026-10-12|container|0|-|1|shared|0|0|0|0|0|0|0|0|0|0|manual\n' >> "$DB_FILE"
ipt() { return 0; }
_fw_chain_ready() { return 0; }
if _fw_build_rules_locked VPSNAT_PRE_A VPSNAT_FWD_A >/dev/null 2>&1; then
  echo 'FAIL: duplicate public port reservations were accepted.' >&2
  exit 1
fi
unset -f ipt _fw_chain_ready

printf 'All VPSNAT self-tests passed.\n'
