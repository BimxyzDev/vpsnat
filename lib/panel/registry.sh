#!/usr/bin/env bash
# Control-plane: registry NODE, alokasi port, dan dispatch job ke node.
#
# Panel tidak menyimpan proses VPS apa pun. Yang disimpan panel:
#   * daftar node + token agent
#   * alokasi port publik per node (satu client = satu port, tidak pernah dibagi)
#   * metadata client: nama, kredensial, IP + port SSH, resource, expiry
#   * job yang sedang berjalan + hasilnya
#
# Semua data itu ada di panel DB (SQLite) dan diakses lewat panelctl.py.

PANELCTL_PY="${VPSNAT_APP_DIR}/panel/panelctl.py"
PANEL_DB_BIN="${VPSNAT_APP_DIR}/panel/db.py"

panel_py() {
  command -v python3 >/dev/null 2>&1 || { err "python3 tidak tersedia."; return 127; }
  [[ -f "$PANELCTL_PY" ]] || { err "panelctl.py tidak ditemukan di ${PANELCTL_PY}."; return 127; }
  local rc
  PYTHONPATH="$(dirname "$PANELCTL_PY")" VPSNAT_PANEL_DB="$PANEL_DB" \
    python3 "$PANELCTL_PY" "$@"
  rc=$?
  return $rc
}

panel_db_init() {
  mkdir -p "$BASE_DIR" 2>/dev/null || true
  panel_py db-init >/dev/null || { err "Gagal menyiapkan panel DB."; return 1; }
  chmod 600 "$PANEL_DB" 2>/dev/null || true
  return 0
}

panel_ready() {
  [[ -s "$PANEL_DB" ]] || { err "Panel DB belum ada. Jalankan: vpsnat install-panel"; return 1; }
}

# --- node registry ---------------------------------------------------------
node_add() {
  need_root
  require_panel_role || return 1
  local name="${1:-}" url="${2:-}" wan="${3:-}" ports="${4:-}" desc="${5:-}" token=""
  if [[ "$NONINTERACTIVE" != "1" ]]; then
    [[ -z "$name" ]] && read -rp "Nama node (a-z0-9-): " name
    [[ -z "$url" ]] && read -rp "URL agent node (http://IP:8788): " url
    [[ -z "$wan" ]] && read -rp "WAN IP node (IP yang dipakai client SSH): " wan
    [[ -z "$ports" ]] && read -rp "Rentang port publik node [20000-24999]: " ports
    ports="${ports:-20000-24999}"
  fi
  token="${VPSNAT_NODE_TOKEN_IN:-}"
  [[ -n "$name" && -n "$url" && -n "$wan" ]] || { err "Pakai: vpsnat node add <nama> <url> <wan-ip> [port-min-max]"; return 1; }
  local args=(node-add "$name" "$url" --wan-ip "$wan" --ports "${ports:-20000-24999}")
  [[ -n "$desc" ]] && args+=(--desc "$desc")
  [[ -n "$token" ]] && args+=(--token "$token")
  panel_py "${args[@]}" || return 1
  audit_log "$(audit_actor_cli)" "node.add" "$name" "ok" "url=${url} ports=${ports}"
}

node_list()   { panel_ready || return 1; panel_py node-list; }
node_show()   { panel_ready || return 1; local a=(node-show "${1:-}"); [[ "${2:-}" == "--token" ]] && a+=(--token); panel_py "${a[@]}"; }
node_ping()   { panel_ready || return 1; panel_py node-ping "${1:-}"; }
node_token()  { panel_ready || return 1; local a=(node-token "${1:-}"); [[ "${2:-}" == "--rotate" ]] && a+=(--rotate); panel_py "${a[@]}"; }

node_del() {
  need_root
  require_panel_role || return 1
  panel_ready || return 1
  local name="${1:-}"
  [[ -z "$name" ]] && { node_list; read -rp "Nama node yang dihapus: " name; }
  confirm "Hapus node '${name}' dari panel? (VPS di node itu TIDAK dihapus)" || return 0
  panel_py node-del "$name" || return 1
  audit_log "$(audit_actor_cli)" "node.del" "$name" "ok"
}

node_addr() {
  # node["url"] + token, dipisah spasi: dipakai helper python.
  panel_ready || return 1
  panel_py node-show "${1:-}" --json --token 2>/dev/null
}

nodes_alloc_list() { panel_ready || return 1; local a=(alloc-list); [[ -n "${1:-}" ]] && a+=("$1"); [[ "${2:-}" == "--free" ]] && a+=(--free); panel_py "${a[@]}"; }

panel_servers_list() { panel_ready || return 1; local a=(server-list); [[ -n "${1:-}" ]] && a+=(--node "$1"); panel_py "${a[@]}"; }
panel_server_show()  { panel_ready || return 1; panel_py server-show "${1:-}" --json; }

# Cek node sehat (dipakai installer & doctor).
node_doctor() {
  panel_ready || return 1
  local rows name
  rows=$(panel_py node-list 2>/dev/null) || return 1
  if [[ -z "${rows//[[:space:]]/}" ]]; then
    warn "Belum ada node terdaftar. Tambahkan: vpsnat node add <nama> <url> <wan-ip>"
    return 0
  fi
  echo "$rows"
  echo
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if node_ping "$name" >/dev/null 2>&1; then ok "Node ${name}: OK"; else warn "Node ${name}: tidak merespons"; fi
  done < <(python3 -c '
import json,os,sys
sys.path.insert(0, os.path.join(sys.argv[1], "panel"))
os.environ.setdefault("VPSNAT_PANEL_DB", sys.argv[2])
import db
print("\n".join(n["name"] for n in db.nodes_all()))
' "$VPSNAT_APP_DIR" "$PANEL_DB" 2>/dev/null)
}

# --- operasi node (dipanggil dari CLI node) --------------------------------
node_init() {
  need_root
  local name="${1:-}"
  [[ -z "$name" ]] && name=$(hostname | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-' | cut -c1-30)
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Nama node tidak valid."; return 1; }
  python3 "${VPSNAT_NODE_DIR}/agent.py" identity --name "$name" >/dev/null || { err "Gagal menulis identitas node."; return 1; }
  local token; token=$(python3 "${VPSNAT_NODE_DIR}/agent.py" token) || return 1
  ok "Node ini siap: ${name}"
  info "Token node : ${token}"
  info "Tempel token di panel: vpsnat node add ${name} http://$(pub_ip):${NODE_AGENT_PORT_DEFAULT} <wan-ip> --token <token>"
  info "Atau di node ini: vpsnat node attach <token-dari-panel>"
}

node_attach() {
  need_root
  local token="${1:-}"
  [[ -z "$token" ]] && { err "Pakai: vpsnat node attach <token>"; return 1; }
  python3 "${VPSNAT_NODE_DIR}/agent.py" attach "$token" || return 1
  systemctl restart "${NODE_AGENT_SERVICE}.service" >/dev/null 2>&1 || true
}

node_status() {
  role_label
  echo
  if [[ -r "$NODE_IDENTITY_FILE" ]]; then
    python3 "${VPSNAT_NODE_DIR}/agent.py" identity 2>/dev/null || true
  else
    info "Identitas node belum dibuat (vpsnat node init)."
  fi
  echo
  systemctl is-active --quiet "${NODE_AGENT_SERVICE}.service" 2>/dev/null \
    && ok "Agent aktif (${NODE_AGENT_SERVICE})" \
    || warn "Agent tidak aktif (${NODE_AGENT_SERVICE})"
}

node_ctl_status() { systemctl status "${NODE_AGENT_SERVICE}.service" --no-pager -n 20; }
node_ctl_logs()   { journalctl -u "${NODE_AGENT_SERVICE}" -n 80 --no-pager; }

node_ctl() {
  need_root
  case "${1:-status}" in
    on) systemctl enable --now "${NODE_AGENT_SERVICE}.service" && ok "Node agent ON." ;;
    off) systemctl disable --now "${NODE_AGENT_SERVICE}.service" && ok "Node agent OFF." ;;
    restart) systemctl restart "${NODE_AGENT_SERVICE}.service" && ok "Node agent restart." ;;
    status) node_ctl_status ;;
    logs) node_ctl_logs ;;
    *) echo "Pakai: vpsnat node-agent [on|off|restart|status|logs]"; return 1 ;;
  esac
}

node_agent_status() { need_root; node_ctl_status; }
node_agent_logs()   { need_root; node_ctl_logs; }
