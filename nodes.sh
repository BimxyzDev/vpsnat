#!/usr/bin/env bash

# ============================================================
# Multi-node dashboard.
#
# Asumsi topologi: semua node vpsnat terhubung ke satu relay
# WireGuard yang sama (lihat relay.sh), sehingga tiap node bisa
# saling menjangkau lewat IP tunnel 10.250.0.x tanpa perlu buka
# firewall publik apa pun. Dashboard menarik data dari node lain
# lewat SSH ke IP tunnel tersebut, menjalankan `vpsnat host --brief`
# di sana, lalu menggabungkan hasilnya dengan node lokal.
#
# Registry node disimpan di ${BASE_DIR}/nodes.conf, format:
#   label|tunnel_ip|ssh_port|ssh_user
# ============================================================

NODES_FILE="${BASE_DIR}/nodes.conf"

nodes_init() {
  mkdir -p "$BASE_DIR"
  touch "$NODES_FILE"
  chmod 600 "$NODES_FILE"
}

node_get() {
  nodes_init
  awk -F'|' -v n="$1" '$1==n{print; exit}' "$NODES_FILE" 2>/dev/null
}

node_add() {
  need_root
  nodes_init
  local label="${1:-}" ip="${2:-}" port="${3:-22}" user="${4:-root}"
  if [[ "$NONINTERACTIVE" != "1" ]]; then
    [[ -z "$label" ]] && read -rp "Label node (mis. upcloud-01): " label
    [[ -z "$ip" ]] && read -rp "IP tunnel node (10.250.0.x): " ip
  fi
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Label tidak valid (a-z0-9-)."; return 1; }
  [[ "$ip" =~ ^10\.250\.0\.[0-9]{1,3}$ ]] || { err "IP harus IP tunnel relay (10.250.0.x)."; return 1; }
  [[ "$port" =~ ^[0-9]+$ ]] || { err "Port SSH harus angka."; return 1; }
  [[ -n "$(node_get "$label")" ]] && { err "Node '${label}' sudah terdaftar. Hapus dulu jika ingin ganti."; return 1; }

  info "Tes koneksi SSH ke ${user}@${ip}:${port}..."
  if ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 -p "$port" "${user}@${ip}" "vpsnat check >/dev/null 2>&1 && echo OK" 2>/dev/null | grep -q OK; then
    warn "Tidak bisa konek/eksekusi 'vpsnat' di node tersebut. Pastikan SSH key sudah ditukar (ssh-copy-id) dan vpsnat sudah terinstall di sana."
    confirm "Tetap simpan node ini?" || return 1
  fi
  printf '%s|%s|%s|%s\n' "$label" "$ip" "$port" "$user" >> "$NODES_FILE"
  ok "Node '${label}' (${ip}) ditambahkan ke registry."
}

node_del() {
  need_root
  nodes_init
  local label="${1:-}"
  [[ -z "$label" ]] && { node_list; read -rp "Label node yang dihapus: " label; }
  [[ -n "$(node_get "$label")" ]] || { err "Node '${label}' tidak ditemukan."; return 1; }
  local tmp; tmp=$(mktemp)
  awk -F'|' -v n="$label" '$1!=n' "$NODES_FILE" > "$tmp" && mv "$tmp" "$NODES_FILE"
  ok "Node '${label}' dihapus dari registry."
}

node_list() {
  nodes_init
  echo -e "${W}Node terdaftar${N} (dashboard menjangkau lewat IP tunnel relay)"
  if [[ ! -s "$NODES_FILE" ]]; then
    echo "(belum ada node lain terdaftar — hanya node lokal ini yang terpantau)"
    return 0
  fi
  printf "%-16s %-16s %-6s %-8s\n" LABEL IP_TUNNEL PORT USER
  awk -F'|' '{printf "%-16s %-16s %-6s %-8s\n", $1, $2, $3, $4}' "$NODES_FILE"
}

# Ringkasan satu baris untuk digabungkan oleh dashboard, dipanggil di node itu sendiri
# (lokal maupun lewat SSH dari node lain).
host_summary_brief() {
  local pubip cpu ram_used ram_tot disk_used disk_tot vps_total vps_running vps_susp label
  pubip=$(pub_ip)
  cpu=$(nproc)
  read -r ram_used ram_tot < <(free -m | awk 'NR==2{print $3, $2}')
  read -r disk_used disk_tot < <(df -h / | awk 'NR==2{gsub("G","",$3); gsub("G","",$2); print $3, $2}')
  vps_total=$(grep -c . "$DB_FILE" 2>/dev/null || echo 0)
  vps_running=0; vps_susp=0
  if [[ -s "$DB_FILE" ]]; then
    local name susp
    while IFS='|' read -r name _ _ _ _ _ _ _ _ _ _ _ susp _; do
      [[ -z "$name" ]] && continue
      [[ "${susp:-0}" == "1" ]] && { vps_susp=$((vps_susp+1)); continue; }
      [[ "$(vps_state "$name")" == "RUNNING" ]] && vps_running=$((vps_running+1))
    done < "$DB_FILE"
  fi
  label=$(conf_get NODE_LABEL); label=${label:-local}
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$label" "$pubip" "$cpu" "${ram_used:-0}" "${ram_tot:-0}" "${disk_used:-0}" "${disk_tot:-0}" \
    "$vps_total" "$vps_running" "$vps_susp"
}

node_set_label() {
  need_root
  local label="${1:-}"
  [[ -z "$label" ]] && read -rp "Label untuk node ini (dipakai di dashboard node lain): " label
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Label tidak valid (a-z0-9-)."; return 1; }
  conf_set NODE_LABEL "$label"
  ok "Label node ini: ${label}"
}

_node_fetch_remote() {
  local ip="$1" port="$2" user="$3" label="$4" out
  out=$(timeout 10 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 -p "$port" "${user}@${ip}" "vpsnat host-brief" 2>/dev/null)
  if [[ -z "$out" ]]; then
    printf '%s|OFFLINE|-|-|-|-|-|-|-|-\n' "$label"
  else
    echo "$out"
  fi
}

nodes_dashboard() {
  nodes_init
  echo -e "${W}${B}=== VPSNAT Multi-Node Dashboard ===${N}"
  echo
  printf "%-14s %-16s %-5s %-12s %-12s %-6s %-6s %-6s\n" LABEL IP CPU RAM DISK TOTAL UP SUSP
  echo "-------------------------------------------------------------------------------"

  local label ip pubip cpu ramu ramt disku diskt vt vr vs
  local total_vps=0 total_running=0 total_susp=0 offline=0

  # Node lokal
  IFS='|' read -r label pubip cpu ramu ramt disku diskt vt vr vs <<< "$(host_summary_brief)"
  printf "%-14s %-16s %-5s %-12s %-12s %-6s %-6s %-6s\n" "${label}(lokal)" "$pubip" "$cpu" "${ramu}/${ramt}M" "${disku}/${diskt}G" "$vt" "$vr" "$vs"
  total_vps=$((total_vps+vt)); total_running=$((total_running+vr)); total_susp=$((total_susp+vs))

  if [[ -s "$NODES_FILE" ]]; then
    local nlabel nip nport nuser row
    while IFS='|' read -r nlabel nip nport nuser; do
      [[ -z "$nlabel" ]] && continue
      row=$(_node_fetch_remote "$nip" "$nport" "$nuser" "$nlabel")
      IFS='|' read -r label pubip cpu ramu ramt disku diskt vt vr vs <<< "$row"
      if [[ "$pubip" == "OFFLINE" ]]; then
        printf "%-14s ${R}%-16s${N} %-5s %-12s %-12s %-6s %-6s %-6s\n" "$label" "OFFLINE" "-" "-" "-" "-" "-" "-"
        offline=$((offline+1))
        continue
      fi
      printf "%-14s %-16s %-5s %-12s %-12s %-6s %-6s %-6s\n" "$label" "$pubip" "$cpu" "${ramu}/${ramt}M" "${disku}/${diskt}G" "$vt" "$vr" "$vs"
      total_vps=$((total_vps+vt)); total_running=$((total_running+vr)); total_susp=$((total_susp+vs))
    done < "$NODES_FILE"
  fi

  echo "-------------------------------------------------------------------------------"
  echo -e "${W}Total gabungan${N}: ${total_vps} VPS (${G}${total_running} running${N}, ${Y}${total_susp} suspend${N})$([[ $offline -gt 0 ]] && echo ", ${R}${offline} node offline${N}")"
}

nodes_dispatch() {
  case "${1:-dashboard}" in
    add) shift; node_add "$@" ;;
    del|rm|remove) shift; node_del "$@" ;;
    list|ls) node_list ;;
    label) shift; node_set_label "$@" ;;
    dashboard|show|"") nodes_dashboard ;;
    *) err "Pakai: vpsnat nodes [dashboard|list|add|del|label]"; return 1 ;;
  esac
}
