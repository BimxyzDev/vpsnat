#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for f in "$ROOT/vpsnat" "$ROOT"/*.sh; do
  bash -n "$f"
done
python3 -m py_compile "$ROOT/bot.py"

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
source "$ROOT/install.sh"
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
resource_cpu_limit_count '0-3' | grep -qx 4
parse_duration 30d >/dev/null

VPSNAT_NONINTERACTIVE=1 settings_set shared-suspend-minutes 60 >/dev/null
[[ "$(conf_get SHARED_SUSPEND_MINUTES)" == "60" ]]

printf 'All VPSNAT self-tests passed.\n'
