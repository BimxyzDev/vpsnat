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
[[ "$VPS_PORTS_MIN" -eq 2 && "$VPS_PORTS_MAX" -eq 50 ]]
[[ "$(vpsnat_read_version "$ROOT/core.sh")" == "$VERSION" ]]
grep -q 'api.github.com/repos/' "$ROOT/update.sh"
grep -q 'with_alloc_lock _vps_create_locked' "$ROOT/vps.sh"
grep -q 'with_alloc_lock _port_add_locked' "$ROOT/ports.sh"
grep -q 'with_alloc_lock _vps_sync_locked' "$ROOT/data.sh"
grep -q 'Gagal mengubah ukuran disk; database tidak diubah.' "$ROOT/vps.sh"

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

printf 'All VPSNAT self-tests passed.\n'
