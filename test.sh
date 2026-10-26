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
source "$ROOT/audit.sh"
source "$ROOT/network.sh"
source "$ROOT/harden.sh"
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

# relay multi-node: slice port, IP tunnel, render config, slice di node
RELAY_NODES_FILE="$tmp/relay-nodes.conf"
printf 'n1|10.250.0.2|%s|20000|24999\nbig|10.250.0.3|%s|30000|39999\n' "$(printf 'A%.0s' {1..43})=" "$(printf 'B%.0s' {1..43})=" > "$RELAY_NODES_FILE"
[[ "$(relay_next_slice 5000)" == "25000-29999" ]]
[[ "$(relay_next_slice 10000)" == "40000-49999" ]]
[[ "$(relay_next_ip)" == "10.250.0.4" ]]
! relay_range_check 21000 22000 >/dev/null 2>&1
! relay_range_check 25000 25050 >/dev/null 2>&1
relay_range_check 25000 29999 >/dev/null 2>&1
rendered=$(relay_render_server_config 51820 PRIVKEY)
[[ "$(grep -c '^\[Peer\]' <<< "$rendered")" == "2" ]]
grep -q -- '--dport 20000:24999 -j DNAT --to-destination 10.250.0.2' <<< "$rendered"
grep -q -- '--dport 30000:39999 -j DNAT --to-destination 10.250.0.3' <<< "$rendered"
grep -q 'AllowedIPs = 10.250.0.3/32' <<< "$rendered"
! grep -q -- '--dport 20000:59999' <<< "$rendered"
# host relay yang juga punya VPS: port VPS lokal tidak boleh masuk slice node
saved_db="$DB_FILE"; saved_nodes="$RELAY_NODES_FILE"
DB_FILE="$tmp/relay-local.db"; RELAY_NODES_FILE="$tmp/relay-empty.conf"; : > "$RELAY_NODES_FILE"
printf 'web|10.10.10.2|20000|1|512|5|tcp:20000:22,tcp:20001:20001|pw|2026-10-01|container|0|-\n' > "$DB_FILE"
[[ "$(relay_next_slice 5000)" == "20002-25001" ]]
! relay_range_check 20000 24999 >/dev/null 2>&1
relay_range_check 30000 34999 >/dev/null 2>&1
DB_FILE="$saved_db"; RELAY_NODES_FILE="$saved_nodes"
printf 'NODE_PORT_MIN=30000\nNODE_PORT_MAX=34999\n' > "$tmp/slice.conf"
[[ "$(VPSNAT_BASE_DIR="$tmp/slice" bash -c 'mkdir -p "$VPSNAT_BASE_DIR"; cp "'"$tmp"'/slice.conf" "$VPSNAT_BASE_DIR/vpsnat.conf"; source "'"$ROOT"'/core.sh"; echo "$PORT_MIN-$PORT_MAX-$SSH_BASE"')" == "30000-34999-30000" ]]

pick_vps() { echo "$1"; }
bandwidth_set() { TEST_QUOTA="$2"; TEST_RATE="$3"; }
export NONINTERACTIVE=1 QUOTA=321 RATE=77
vps_bandwidth legacy set
[[ "$TEST_QUOTA" == "321" && "$TEST_RATE" == "77" ]]

# Regresi: perpanjangan tidak boleh membuka suspension manual.
printf 'manual|10.10.10.4|20012|1|1024|10|tcp:20012:22|pass|2026-01-01|container|0|-|1|shared|0|0|0|0|0|0|0|0|0|0|manual\n' >> "$DB_FILE"
need_root() { :; }  # test terisolasi; tidak mengubah host/LXD.
conf_set PREFLIGHT 0 >/dev/null  # preflight ruang disk diuji terpisah di blok v3.4.0
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

# ============================== v3.4.0 ==============================
# Catatan: `! cmd` tidak menggagalkan skrip di bawah `set -e`; assert_* di bawah memakai exit eksplisit.
t_fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || t_fail "$3: dapat '$1', harus '$2'"; }
assert_ok() { "$@" >/dev/null 2>&1 || t_fail "harus sukses: $*"; }
assert_fail() { if "$@" >/dev/null 2>&1; then t_fail "harus gagal: $*"; fi; }
assert_has() { grep -qF -- "$2" <<< "$1" || t_fail "$3: tidak memuat '$2'"; }
assert_lacks() { if grep -qF -- "$2" <<< "$1"; then t_fail "$3: tidak boleh memuat '$2'"; fi; }

# --- B2: alokasi port multi-blok (greedy best-fit) -------------------------------------------
# Layout 20000-20029: bebas 20000-20003(4) 20006-20012(7) 20014-20016(3) 20020-20029(10).
FRAG_ROWS=(
  'a|10.10.10.2|20004|1|1024|10|tcp:20004:22,tcp:20005:20005|pw|2026-01-01|container|0|-|0'
  'b|10.10.10.3|20013|1|1024|10|tcp:20013:22|pw|2026-01-01|container|0|-|0'
  'c|10.10.10.4|20017|1|1024|10|tcp:20017:22,tcp:20018:20018,tcp:20019:20019|pw|2026-01-01|container|0|-|0'
)
write_frag_db() { printf '%s\n' "${FRAG_ROWS[@]}" > "$1"; }
(
  ss() { return 0; }
  write_frag_db "$tmp/frag.db"
  DB_FILE="$tmp/frag.db"; SSH_BASE=20000; PORT_MAX=20029
  CONF_FILE="$tmp/conf-frag"; : > "$CONF_FILE"
  assert_eq "$(port_free_runs | tr '\n' ';')" "20000 20003;20006 20012;20014 20016;20020 20029;" "port_free_runs"
  assert_eq "$(alloc_contiguous_ports 7)" "20006 20012" "first-fit kontigu"
  assert_fail alloc_contiguous_ports 11
  assert_eq "$(alloc_ports 7 | tr '\n' ' ')" "20006 20007 20008 20009 20010 20011 20012 " "alloc_ports kontigu"
  mapfile -t got <<< "$(alloc_ports 11)"
  assert_eq "${#got[@]}" 11 "jumlah port split"
  assert_eq "$(port_ranges_label "${got[@]}")" "20014,20020-20029" "split best-fit"
  assert_eq "$(printf '%s\n' "${got[@]}" | sort -u | wc -l | tr -d ' ')" 11 "port unik"
  mapfile -t got <<< "$(alloc_ports 21)"
  assert_eq "${#got[@]}" 21 "tiga blok"
  assert_eq "$(port_ranges_label "${got[@]}")" "20000-20003,20006-20012,20020-20029" "tiga blok urut naik"
  assert_fail alloc_ports 22
  conf_set PORT_SPLIT_MAX_CHUNKS 1 >/dev/null
  assert_fail alloc_ports 11
  assert_ok alloc_ports 7
  assert_eq "$(port_ranges_label 1 2 3 7 9 10)" "1-3,7,9-10" "label rentang"
)
(
  ss() { return 0; }
  write_frag_db "$tmp/frag2.db"
  DB_FILE="$tmp/frag2.db"; SSH_BASE=20000; PORT_MAX=20029
  CONF_FILE="$tmp/conf-frag2"; : > "$CONF_FILE"
  need_root() { :; }; apply_all_rules() { return 0; }; pick_vps() { echo "$1"; }
  PROTO=tcp COUNT=11 port_add c >/dev/null
  ports=$(db_field c 7)
  assert_has "$ports" "tcp:20014:20014" "mapping identitas blok 1"
  assert_has "$ports" "tcp:20029:20029" "mapping identitas blok 2"
  assert_eq "$(tr ',' '\n' <<< "$ports" | wc -l | tr -d ' ')" 14 "jumlah entri port"
)
(
  ss() { return 0; }
  write_frag_db "$tmp/frag3.db"
  DB_FILE="$tmp/frag3.db"; SSH_BASE=20000; PORT_MAX=20029
  CONF_FILE="$tmp/conf-frag3"; : > "$CONF_FILE"
  need_root() { :; }; apply_all_rules() { return 0; }; pick_vps() { echo "$1"; }
  PROTO=tcp COUNT=11 INT_START=3000 port_add c >/dev/null
  ports=$(db_field c 7)
  assert_has "$ports" "tcp:20014:3000" "INT_START eksplisit: port internal berurutan"
  assert_has "$ports" "tcp:20020:3001" "INT_START eksplisit: lintas blok"
)

# --- A3 + SMTP: guard firewall per-VPS ---------------------------------------------------------
fw_guard_db() {
  printf '%s\n' \
    'g1|10.10.10.21|21001|1|1024|10|tcp:21001:22|pw|2026-10-12|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-' \
    'g2|10.10.10.22|21002|1|1024|10|tcp:21002:22|pw|2026-10-12|container|0|-|0|dedicated|0|0|0|0|0|0|0|0|0|0|-' \
    'g3|10.10.10.23|21003|1|1024|10|tcp:21003:22|pw|2026-10-12|container|0|-|1|shared|0|0|0|0|0|0|0|0|0|0|manual' > "$1"
}
(
  IPT_LOG="$tmp/ipt-guard.log"
  ipt() { printf '%s\n' "$*" >> "$IPT_LOG"; return 0; }
  _fw_chain_ready() { return 0; }
  fw_guard_db "$tmp/fw.db"; DB_FILE="$tmp/fw.db"
  CONF_FILE="$tmp/conf-fw"; : > "$CONF_FILE"
  : > "$IPT_LOG"; _fw_build_rules_locked STAGE_PRE STAGE_FWD >/dev/null 2>&1 || t_fail "build rules default"
  out=$(cat "$IPT_LOG")
  smtp1='-A STAGE_FWD -s 10.10.10.21 -p tcp -m multiport --dports 25,465,587 -j REJECT --reject-with tcp-reset'
  conn1='-A STAGE_FWD -s 10.10.10.21 -m conntrack --ctstate NEW -m connlimit --connlimit-above 1024 --connlimit-mask 32 -j REJECT'
  assert_has "$out" "$smtp1" "SMTP g1"
  assert_has "$out" "$conn1" "connlimit g1"
  assert_has "$out" "-A STAGE_FWD -s 10.10.10.22 -p tcp -m multiport --dports 25,465,587" "SMTP g2 (dedicated)"
  assert_lacks "$out" "-s 10.10.10.23 -p tcp -m multiport" "VPS suspended tidak diberi guard SMTP"
  assert_lacks "$out" "-s 10.10.10.23 -m conntrack" "VPS suspended tidak diberi connlimit"
  est=$(grep -nF -- '--ctstate ESTABLISHED,RELATED -j ACCEPT' "$IPT_LOG" | head -1 | cut -d: -f1)
  gl=$(grep -nF -- "$conn1" "$IPT_LOG" | head -1 | cut -d: -f1)
  br=$(grep -nF -- "-A STAGE_FWD -i $BRIDGE -j ACCEPT" "$IPT_LOG" | head -1 | cut -d: -f1)
  (( est < gl && gl < br )) || t_fail "urutan: ESTABLISHED ($est) < guard ($gl) < bridge ACCEPT ($br)"

  conf_set SMTP_BLOCK 0 >/dev/null; conf_set CONN_LIMIT 2048 >/dev/null
  : > "$IPT_LOG"; _fw_build_rules_locked STAGE_PRE STAGE_FWD >/dev/null 2>&1 || t_fail "build rules smtp off"
  out=$(cat "$IPT_LOG")
  assert_lacks "$out" "multiport" "SMTP_BLOCK=0 tanpa rule multiport"
  assert_has "$out" "--connlimit-above 2048" "CONN_LIMIT kustom"

  conf_set SMTP_BLOCK 1 >/dev/null; conf_set CONN_LIMIT 0 >/dev/null; conf_set SMTP_BLOCK_PORTS 25,2525 >/dev/null
  : > "$IPT_LOG"; _fw_build_rules_locked STAGE_PRE STAGE_FWD >/dev/null 2>&1 || t_fail "build rules conn off"
  out=$(cat "$IPT_LOG")
  assert_lacks "$out" "connlimit" "CONN_LIMIT=0 tanpa rule connlimit"
  assert_has "$out" "--dports 25,2525 -j REJECT" "daftar port SMTP kustom"

  conf_set SMTP_BLOCK_PORTS "bukan;port" >/dev/null; conf_set CONN_LIMIT 1024 >/dev/null
  : > "$IPT_LOG"; _fw_build_rules_locked STAGE_PRE STAGE_FWD >/dev/null 2>&1 || t_fail "build rules port invalid"
  assert_has "$(cat "$IPT_LOG")" "--dports 25,465,587 -j REJECT" "port SMTP invalid kembali ke default"

  # Kernel tanpa xt_connlimit: guard dilewati, firewall tetap berhasil dibangun.
  ipt() { if [[ "$*" == *connlimit* ]]; then return 1; fi; printf '%s\n' "$*" >> "$IPT_LOG"; return 0; }
  : > "$IPT_LOG"; _fw_build_rules_locked STAGE_PRE STAGE_FWD >/dev/null 2>&1 || t_fail "tanpa xt_connlimit harus tetap sukses"
  out=$(cat "$IPT_LOG")
  assert_lacks "$out" "connlimit" "tanpa modul: tidak ada rule connlimit"
  assert_has "$out" "--dports 25,465,587 -j REJECT" "tanpa connlimit: SMTP tetap diblokir"
)

# --- A2: penalti leaky bucket -------------------------------------------------------------------
assert_eq "$(penalty_next 0 15 1 1 25 60)" "15.00" "skor naik saat beban penuh"
assert_eq "$(penalty_next 15 15 0 1 25 60)" "11.25" "skor turun 25% saat normal"
assert_eq "$(penalty_next 1 15 0 1 25 60)" "0.00" "skor tidak negatif"
assert_eq "$(penalty_next 20 15 0 0 25 60)" "20.00" "CPU tak diketahui: skor tetap"
assert_eq "$(penalty_next 0 600 1 1 25 60)" "60.00" "langkah dt dibatasi cap"
(
  # Pola duty-cycle 3 sampel penuh : 1 sampel normal tetap terakumulasi (versi lama: tak pernah suspend).
  s=0; n=0
  until awk -v s="$s" 'BEGIN { exit !(s >= 3600) }'; do
    for hi in 1 1 1 0; do s=$(penalty_next "$s" 15 "$hi" 1 25 60); done
    n=$((n + 1)); (( n < 500 )) || t_fail "duty-cycle tidak pernah mencapai ambang"
  done
  (( n >= 80 && n <= 95 )) || t_fail "jumlah siklus duty-cycle tidak wajar: $n"
  # Beban normal terus-menerus tidak pernah menumpuk skor.
  s=10
  for _ in $(seq 1 200); do s=$(penalty_next "$s" 15 0 1 25 60); done
  assert_eq "$s" "0.00" "beban normal menghapus skor"
)
pen_setup() {   # pen_setup <menit_suspend>
  CONF_FILE="$tmp/conf-pen-$$-$RANDOM"; : > "$CONF_FILE"; conf_set SHARED_SUSPEND_MINUTES "$1" >/dev/null
  DB_FILE="$tmp/pen-$$-$RANDOM.db"
  printf '%s\n' 'pen1|10.10.10.50|20500|2|1024|10|tcp:20500:22|pw|2026-01-01|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-' > "$DB_FILE"
  MONITOR_DIR="$tmp/mon-pen-$$-$RANDOM"; mkdir -p "$MONITOR_DIR"
  SIM_NOW=1790000000; SIM_SUSP=0; SIM_CPU=0; SIM_MEM=0
  date() { if [[ "${1:-}" == "+%s" ]]; then echo "$SIM_NOW"; else command date "$@"; fi; }
  resource_metrics() { echo "10.0|${SIM_CPU}|${SIM_MEM}"; }
  _vps_suspend_auto() { SIM_SUSP=$((SIM_SUSP + 1)); db_set_fields "$1" "13=1" "25=$2" "20=0"; penalty_reset "$1"; }
  tg_notify() { :; }
  sim_cycle() { SIM_CPU="$1"; SIM_MEM="$2"; SIM_NOW=$((SIM_NOW + 15)); db_set_fields pen1 "22=$((SIM_NOW - 15))"; resource_update_one pen1; }
}
(
  pen_setup 1
  sim_cycle 99.50 10.00; assert_eq "$(penalty_get pen1)" "15.00" "siklus 1"
  sim_cycle 99.50 10.00; sim_cycle 99.50 10.00
  assert_eq "$(penalty_get pen1)" "45.00" "siklus 3"
  sim_cycle 10.00 10.00
  assert_eq "$(penalty_get pen1)" "41.25" "1 sampel normal hanya mengurangi, tidak mereset"
  sim_cycle 99.50 10.00
  assert_eq "$(penalty_get pen1)" "56.25" "naik lagi"
  assert_eq "$SIM_SUSP" 0 "belum suspend"
  sim_cycle 99.50 10.00
  assert_eq "$SIM_SUSP" 1 "suspend setelah akumulasi mencapai ambang"
  assert_eq "$(db_field pen1 13)" 1 "DB menandai suspended"
  [[ ! -e "$(penalty_file pen1)" ]] || t_fail "file penalti harus dihapus setelah suspend"
)
(
  pen_setup 60
  sim_cycle 97.00 99.00; assert_eq "$(penalty_get pen1)" "0" "CPU 97 dan RAM 99 bukan beban penuh"
  sim_cycle 98.00 10.00; assert_eq "$(penalty_get pen1)" "15.00" "CPU >= 98 (100 - toleransi 2) dihitung"
  sim_cycle -1 10.00;    assert_eq "$(penalty_get pen1)" "15.00" "CPU tak diketahui tidak mereset skor"
  sim_cycle 10.00 100.00; assert_eq "$(penalty_get pen1)" "30.00" "RAM 100% dihitung (tanpa toleransi)"
  conf_set SHARED_CPU_TOLERANCE 0 >/dev/null
  sim_cycle 99.00 10.00; assert_eq "$(penalty_get pen1)" "26.25" "toleransi 0: CPU 99 dianggap normal"
)
(
  pen_setup 60
  db_set_fields pen1 "20=$((SIM_NOW + 15 - 100))"   # saat siklus berjalan now = SIM_NOW+15 -> beban beruntun 100 detik
  sim_cycle 10.00 10.00
  assert_eq "$(penalty_get pen1)" "96.25" "migrasi high_since (kolom 20) menjadi skor awal"
  assert_eq "$(db_field pen1 20)" 0 "kolom 20 dikosongkan"
)
(
  pen_setup 1
  _vps_suspend_auto() { SIM_SUSP=$((SIM_SUSP + 1)); return 1; }   # mis. lock alokasi timeout: DB tidak berubah
  for _ in 1 2 3 4; do sim_cycle 99.50 10.00; done
  assert_eq "$SIM_SUSP" 1 "percobaan suspend pertama"
  assert_eq "$(db_field pen1 13)" 0 "belum tersuspend"
  assert_eq "$(penalty_get pen1)" "60.00" "skor dipertahankan untuk retry"
  sim_cycle 99.50 10.00
  assert_eq "$SIM_SUSP" 2 "retry di siklus berikutnya"
)

# --- A1 + D3: hardening LXD -----------------------------------------------------------------------
(
  LXC_LOG="$tmp/lxc-harden.log"
  lxc() { printf '%s\n' "$*" >> "$LXC_LOG"; return 0; }
  CONF_FILE="$tmp/conf-h"; : > "$CONF_FILE"
  : > "$LXC_LOG"; assert_ok vps_harden_apply web1 shared container
  out=$(cat "$LXC_LOG")
  assert_has "$out" "config set web1 limits.processes 512" "limit proses shared"
  assert_has "$out" "config device set web1 eth0 security.mac_filtering true" "mac filtering"
  assert_has "$out" "config device set web1 eth0 security.ipv4_filtering true" "ipv4 filtering"
  assert_has "$out" "config device set web1 eth0 security.ipv6_filtering true" "ipv6 filtering"
  : > "$LXC_LOG"; vps_harden_apply web2 dedicated container
  assert_has "$(cat "$LXC_LOG")" "config set web2 limits.processes 2048" "limit proses dedicated"
  : > "$LXC_LOG"; vps_harden_apply vm1 shared vm
  out=$(cat "$LXC_LOG")
  assert_lacks "$out" "limits.processes" "VM tidak mengenal limits.processes"
  assert_has "$out" "config device set vm1 eth0 security.mac_filtering true" "VM tetap dapat anti-spoofing"
  conf_set PROC_LIMIT_SHARED 0 >/dev/null
  : > "$LXC_LOG"; vps_harden_apply web3 shared container
  assert_has "$(cat "$LXC_LOG")" "config unset web3 limits.processes" "limit 0 = hapus batas"
  conf_set ANTISPOOF 0 >/dev/null
  : > "$LXC_LOG"; vps_harden_apply web4 shared container
  out=$(cat "$LXC_LOG")
  assert_lacks "$out" "security.mac_filtering true" "ANTISPOOF=0 tidak mengaktifkan filter"
  assert_has "$out" "config device unset web4 eth0 security.mac_filtering" "ANTISPOOF=0 mencabut filter"
  conf_set ANTISPOOF 1 >/dev/null
  # device NIC masih dari profile: fallback ke override
  lxc() { printf '%s\n' "$*" >> "$LXC_LOG"; [[ "$1 $2 $3" == "config device set" ]] && return 1; return 0; }
  : > "$LXC_LOG"; assert_ok vps_harden_apply web5 shared container
  assert_has "$(cat "$LXC_LOG")" "config device override web5 eth0 security.mac_filtering=true" "fallback override"
  # set dan override sama-sama gagal -> dilaporkan gagal (create hanya memberi peringatan)
  lxc() { [[ "$1 $2" == "config device" ]] && return 1; return 0; }
  assert_fail vps_harden_apply web6 shared container
)
(
  plan_type() { echo shared; }; vps_type() { echo container; }
  CONF_FILE="$tmp/conf-h1"; : > "$CONF_FILE"
  lxc() { case "$*" in
      "config get web1 limits.processes") echo 512 ;;
      *"security.mac_filtering"|*"security.ipv4_filtering") echo true ;;
    esac; return 0; }
  assert_ok harden_report_one web1
  lxc() { return 0; }
  assert_fail harden_report_one web1
)
(
  LXC_LOG="$tmp/lxc-e2e.log"; : > "$LXC_LOG"
  lxc() { printf '%s\n' "$*" >> "$LXC_LOG"; return 0; }
  CONF_FILE="$tmp/conf-h2"; : > "$CONF_FILE"
  DB_FILE="$tmp/h2.db"
  printf '%s\n' \
    'h1|10.10.10.61|21101|1|1024|10|tcp:21101:22|pw|2026-01-01|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-' \
    'h2|10.10.10.62|21102|1|1024|10|tcp:21102:22|pw|2026-01-01|container|0|-|0|dedicated|0|0|0|0|0|0|0|0|0|0|-' > "$DB_FILE"
  vps_exists() { return 0; }; vps_state() { echo STOPPED; }
  VPSNAT_YES=1 vps_harden all >/dev/null 2>&1 || t_fail "vps_harden all"
  out=$(cat "$LXC_LOG")
  assert_has "$out" "config set h1 limits.processes 512" "harden all: h1"
  assert_has "$out" "config set h2 limits.processes 2048" "harden all: h2"
  assert_fail vps_harden --check
  lxc() { case "$*" in
      "config get h1 limits.processes") echo 512 ;;
      "config get h2 limits.processes") echo 2048 ;;
      *"security.mac_filtering"|*"security.ipv4_filtering") echo true ;;
    esac; return 0; }
  assert_ok vps_harden --check
  assert_fail vps_harden nope
)

# --- C3: preflight ruang disk --------------------------------------------------------------------
(
  CONF_FILE="$tmp/conf-pf"; : > "$CONF_FILE"
  GB=1073741824
  storage_free_bytes() { echo "$MOCK_FREE"; }
  storage_driver() { echo "$MOCK_DRIVER"; }
  vps_used_bytes() { echo "$MOCK_USED"; }
  path_free_bytes() { echo "$MOCK_FREE"; }
  MOCK_DRIVER=dir; MOCK_USED=0
  MOCK_FREE=3000000000; assert_fail preflight_space uji 1000000000       # 1.2e9 + 2GiB > 3e9
  MOCK_FREE=4000000000; assert_ok preflight_space uji 1000000000
  MOCK_FREE=$((7 * GB)); assert_ok preflight_create 100                   # 3GiB x1.2 + 2GiB = 5.6GiB
  MOCK_FREE=$((5 * GB)); assert_fail preflight_create 100
  assert_ok preflight_create 1                                            # kuota kecil: 1GiB x1.2 + 2GiB
  MOCK_DRIVER=zfs; MOCK_USED=$((50 * GB)); MOCK_FREE=$((3 * GB))
  assert_ok preflight_vps_copy web1 "clone web1"                          # copy-on-write: cukup buffer
  MOCK_FREE=$((1 * GB)); assert_fail preflight_vps_copy web1 "clone web1"
  MOCK_DRIVER=dir; MOCK_USED=$((2 * GB)); MOCK_FREE=$((4 * GB))
  assert_fail preflight_vps_copy web1 "clone web1"                        # salinan penuh 2.4GiB + 2GiB > 4GiB
  MOCK_FREE=$((5 * GB)); assert_ok preflight_vps_copy web1 "clone web1"
  MOCK_FREE=$((1 * GB)); assert_fail preflight_backup web1 "$tmp"
  MOCK_FREE=$((10 * GB)); assert_ok preflight_backup web1 "$tmp"
  truncate -s 10M "$tmp/restore-test.tar.gz"
  MOCK_FREE=$((100 * 1024 * 1024)); assert_fail preflight_restore "$tmp/restore-test.tar.gz"
  MOCK_FREE=$((3 * GB)); assert_ok preflight_restore "$tmp/restore-test.tar.gz"
  MOCK_FREE=""; assert_ok preflight_space uji $((100 * GB))              # tak terdeteksi: fail-open
  conf_set PREFLIGHT 0 >/dev/null; MOCK_FREE=0
  assert_ok preflight_space uji $((100 * GB))                             # dimatikan
)

# --- D4: backup DB -------------------------------------------------------------------------------
(
  DB_BACKUP_DIR="$tmp/dbbk"; CONF_FILE="$tmp/conf-bk"; : > "$CONF_FILE"
  DB_FILE="$tmp/bk.db"
  printf '%s\n\n' 'x|10.10.10.2|20000|1|1024|10|tcp:20000:22|pw|2026-01-01|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-' > "$DB_FILE"
  assert_eq "$(db_rows_count "$DB_FILE")" 1 "baris kosong tidak dihitung"
  assert_ok db_verify_file "$DB_FILE"
  p=$(db_backup_snapshot pre-upgrade v3.4.0)
  [[ -f "$p" ]] || t_fail "backup tidak dibuat"
  cmp -s "$p" "$DB_FILE" || t_fail "isi backup berbeda dari DB"
  assert_eq "$(stat -c %a "$p")" 600 "mode backup"
  assert_eq "$(stat -c %a "$DB_BACKUP_DIR")" 700 "mode folder backup"
  for _ in 1 2 3 4 5 6 7; do db_backup_snapshot pre-upgrade v3.4.0 >/dev/null; done
  assert_eq "$(ls -1 "$DB_BACKUP_DIR" | wc -l | tr -d ' ')" 5 "rotasi DB_BACKUP_KEEP"
  printf '%s\n' 'bad||20000' > "$tmp/bad.db"
  assert_fail db_verify_file "$tmp/bad.db"
)

# --- B3: MSS clamp relay/node -------------------------------------------------------------------
(
  conf=$(relay_render_server_config 51820 PRIVKEY)
  assert_has "$conf" "PostUp = iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" "server config: PostUp MSS"
  assert_has "$conf" "PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" "server config: PostDown MSS"
)
(
  RELAY_WG_CONF="$tmp/wg-legacy.conf"
  printf '[Interface]\nAddress = 10.250.0.1/24\nListenPort = 51820\nPrivateKey = KEY\n\nPostUp = iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n\n[Peer]\nPublicKey = P\nAllowedIPs = 10.250.0.2/32\n' > "$RELAY_WG_CONF"
  assert_ok relay_mss_conf_patch
  assert_eq "$(grep -c 'TCPMSS --clamp-mss-to-pmtu' "$RELAY_WG_CONF")" 2 "patch menyisipkan PostUp+PostDown"
  assert_eq "$(awk '/^PrivateKey/ {f = 1; next} f && /^PostUp/ {print "ok"; exit}' "$RELAY_WG_CONF")" ok "MSS berada di section Interface"
  relay_mss_conf_patch
  assert_eq "$(grep -c 'TCPMSS --clamp-mss-to-pmtu' "$RELAY_WG_CONF")" 2 "patch idempoten"
  assert_eq "$(stat -c %a "$RELAY_WG_CONF")" 600 "mode config"
  assert_has "$(cat "$RELAY_WG_CONF")" "AllowedIPs = 10.250.0.2/32" "section Peer utuh"
)
(
  IPL="$tmp/ipt-mss.log"; : > "$IPL"; flag="$tmp/mss.flag"; rm -f "$flag"
  iptables() {
    printf '%s\n' "$*" >> "$IPL"
    case " $* " in
      *" -C "*) [[ -f "$flag" ]]; return ;;
      *" -A "*) : > "$flag"; return 0 ;;
    esac
    return 0
  }
  relay_mss_apply
  assert_eq "$(grep -c -- ' -A ' "$IPL")" 1 "pertama kali: rule dipasang sekali"
  relay_mss_apply
  assert_eq "$(grep -c -- ' -A ' "$IPL")" 1 "kedua kali: tidak menggandakan rule"
)
grep -q 'PostUp = ${RELAY_MSS_UP}' "$ROOT/relay.sh"   # config node (attach) juga memasang MSS clamp

# --- Settings hardening -------------------------------------------------------------------------
(
  CONF_FILE="$tmp/conf-set"; : > "$CONF_FILE"
  apply_all_rules() { return 0; }
  assert_ok settings_set conn-limit 500
  assert_eq "$(conf_get CONN_LIMIT)" 500 "conn-limit tersimpan"
  assert_fail settings_set conn-limit 5
  assert_ok settings_set conn-limit 0
  assert_ok settings_set smtp-block 0
  assert_fail settings_set smtp-block 2
  assert_ok settings_set proc-limit-shared 0
  assert_fail settings_set proc-limit-shared 5
  assert_ok settings_set proc-limit-dedicated 4096
  assert_eq "$(conf_get PROC_LIMIT_DEDICATED)" 4096 "proc-limit-dedicated tersimpan"
  assert_ok settings_set shared-cpu-tolerance 0
  assert_fail settings_set shared-cpu-tolerance 51
  assert_has "$(settings_show)" "CONN_LIMIT" "settings show memuat CONN_LIMIT"
  assert_has "$(settings_show)" "PROC_LIMIT_SHARED" "settings show memuat PROC_LIMIT_SHARED"
)

# --- Integrasi modul (struktural) ---------------------------------------------------------------
grep -q 'harden.sh' "$ROOT/vpsnat"
grep -q 'preflight_create' "$ROOT/vps.sh"
grep -q 'vps_harden_apply' "$ROOT/vps.sh"
grep -q 'preflight_vps_copy' "$ROOT/data.sh"
grep -q 'db_backup_snapshot pre-upgrade' "$ROOT/install.sh"
grep -q 'VPSNAT_ALLOC_LOCK_TIMEOUT' "$ROOT/resource.sh"
grep -q 'cmd_restore' "$ROOT/cli.sh"
grep -q 'harden) vps_harden' "$ROOT/cli.sh"
[[ "$VERSION" == "3.4.1" ]]
grep -q '^## 3.4.1' "$ROOT/CHANGELOG.md"
grep -q '^## 3.4.0' "$ROOT/CHANGELOG.md"

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

# ============================== v3.4.1 ==============================
# --- Batch DB: baca dari cache + satu penulisan untuk banyak VPS ---
(
  DB_FILE="$tmp/batch.db"; CONF_FILE="$tmp/conf-batch"; : > "$CONF_FILE"
  DB_BACKUP_DIR="$tmp/dbbatch"; mkdir -p "$DB_BACKUP_DIR"
  i=0; : > "$DB_FILE"
  while (( i < 50 )); do
    i=$((i+1))
    printf 'b%02d|10.10.10.%d|%d|1|1024|10|tcp:%d:22|pw|2026-01-01|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-\n' \
      "$i" "$i" "$((20000+i))" "$((20000+i))" >> "$DB_FILE"
  done
  before=$(cksum < "$DB_FILE")
  assert_ok db_cache_load
  assert_eq "$(db_field b07 2)" "10.10.10.7" "db_field lewat cache"
  assert_ok db_row b07
  assert_eq "${DB_ROW[0]}|${DB_ROW[1]}" "b07|10.10.10.7" "db_row 25 field satu pass"
  db_batch_begin
  i=0; while (( i < 50 )); do i=$((i+1)); db_batch_set "b0$i" "21=3" "22=4"; done 2>/dev/null || true
  db_batch_set b07 "21=7" "22=8"
  assert_ok db_batch_commit
  db_cache_clear
  assert_eq "$(db_field b07 21)/$(db_field b07 22)" "7/8" "batch menulis field yang diminta"
  assert_eq "$(db_field b01 21)" "3" "batch menulis VPS lain dalam satu commit"
  assert_eq "$(awk -F'|' '{print NF}' "$DB_FILE" | sort -u | tr -d '\n')" "25" "schema tetap 25 field"
  assert_eq "$(awk 'NF' "$DB_FILE" | wc -l | tr -d ' ')" "50" "tidak ada baris hilang"
  [[ "$before" != "$(cksum < "$DB_FILE")" ]] || t_fail "batch harus mengubah file"
  # field yang tidak diminta tidak boleh ikut berubah
  assert_eq "$(db_field b07 2)" "10.10.10.7" "field lain utuh setelah batch"
  assert_eq "$(db_field b07 7)" "tcp:20007:22" "mapping port utuh setelah batch"
  # batch kosong harus no-op
  db_batch_begin
  assert_ok db_batch_commit
  assert_ok db_cache_clear
)

# --- Alokasi IP/port: hasil sama, tanpa loop grep/ss per kandidat ---
(
  DB_FILE="$tmp/alloc.db"; DB_FILE="$tmp/alloc.db"
  printf '%s\n' \
    'a|10.10.10.2|20000|1|512|5|tcp:20000:22|p|2026-01-01|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-' \
    'c|10.10.10.4|20002|1|512|5|tcp:20002:22|p|2026-01-01|container|0|-|0|shared|0|0|0|0|0|0|0|0|0|0|-' > "$DB_FILE"
  assert_eq "$(next_ip)" "10.10.10.3" "next_ip melompati IP terpakai"
  conf_set NODE_PORT_MIN 20000 >/dev/null 2>&1 || true
  SSH_BASE=20000; PORT_MAX=20010
  assert_eq "$(next_ssh_port)" "20001" "next_ssh_port memakai port kosong pertama"
)

# --- Audit trail (JSONL, append-only, tanpa rahasia) ---
(
  AUDIT_FILE="$tmp/audit.log"; CONF_FILE="$tmp/conf-audit"; : > "$CONF_FILE"
  audit_log "cli:root" "vps.create" "v1" "ok" "plan=shared"
  audit_log "bot:1" "vps.delete" 'we"ird' "ok" 'a "quoted" \ detail'
  [[ -s "$AUDIT_FILE" ]] || t_fail "audit file harus dibuat"
  assert_eq "$(wc -l < "$AUDIT_FILE" | tr -d ' ')" "2" "dua baris audit"
  while IFS= read -r line; do
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert set(d)>= {"ts","actor","action","target","result","detail"}' "$line" \
      || t_fail "baris audit bukan JSON valid: $line"
  done < "$AUDIT_FILE"
  assert_eq "$(stat -c %a "$AUDIT_FILE")" "600" "mode audit 600"
  assert_has "$(audit_cmd tail 5)" "vps.create" "audit tail memuat aksi"
  assert_has "$(audit_cmd search vps.delete 5)" "bot:1" "audit search memfilter"
  # AUDIT_LOG=0 mematikan pencatatan
  conf_set AUDIT_LOG 0 >/dev/null
  audit_log "cli:root" "vps.nope" "x" "ok"
  assert_eq "$(wc -l < "$AUDIT_FILE" | tr -d ' ')" "2" "AUDIT_LOG=0 tidak menambah baris"
)

# --- resource_metrics: konversi & persentase harus identik dengan aritmetika lama ---
(
  db_field_var() {
    case "$2:$3" in
      "v1:5") printf -v "$1" '%s' 1024 ;;
      "v1:21") printf -v "$1" '%s' 10 ;;
      "v1:22") printf -v "$1" '%s' "$SIM_NOW" ;;
      *) printf -v "$1" '%s' "" ;;
    esac
  }
  CYCLE_NOW=1780000015; SIM_NOW=1780000000
  LXD_BULK_LOADED=1; LXD_CPU_NS[v1]=25000000000; LXD_MEM_BYTES[v1]=536870912; LXD_CPU_LIMIT[v1]=2
  assert_eq "$(resource_metrics v1)" "25.000000000|50.00|50.00" "cpu 15s/15s/2core, ram 512/1024"
  LXD_CPU_NS[v1]=10000000000
  assert_eq "$(resource_metrics v1)" "10.000000000|0.00|50.00" "cpu tanpa kenaikan"
  LXD_CPU_NS[v1]=9999999999
  assert_eq "$(resource_metrics v1)" "9.999999999|-1|50.00" "counter turun -> -1"
  LXD_MEM_BYTES[v1]=1073741824
  assert_eq "$(resource_metrics v1)" "9.999999999|-1|100.00" "ram penuh"
  LXD_CPU_LIMIT[v1]=""
  assert_eq "$(resource_metrics v1)" "9.999999999|-1|100.00" "cpu limit kosong tetap jalan"
  unset LXD_BULK_LOADED
)

# --- next_ip/port & guard struktural v3.4.1 ---
grep -q 'db_cache_load' "$ROOT/resource.sh"
grep -q 'db_batch_commit' "$ROOT/resource.sh"
grep -q 'db_metric_write' "$ROOT/bandwidth.sh"
grep -q 'lxd_bulk_load' "$ROOT/db.sh"
grep -q 'vps_states_load' "$ROOT/vps.sh"
grep -q 'audit.sh' "$ROOT/vpsnat"
grep -q 'audit) audit_cmd' "$ROOT/cli.sh"
grep -q 'SAFE_NAME_RE' "$ROOT/web.py"
grep -q 'def origin_ok' "$ROOT/web.py"
grep -q 'token_urlsafe(16)' "$ROOT/bot.py"
grep -q '_CB_NAME_AT' "$ROOT/bot.py"
grep -q 'AUDIT' "$ROOT/web.py"
