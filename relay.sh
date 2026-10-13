#!/usr/bin/env bash

# Universal relay mode: one public relay VPS forwards the configured public
# port range over WireGuard to one VPSNAT node. The node keeps its normal
# VPSNAT DNAT rules, so tenant provisioning logic does not change.

RELAY_WG_IF="${RELAY_WG_IF:-wg-vpsnat}"
RELAY_WG_DIR="${RELAY_WG_DIR:-/etc/wireguard}"
RELAY_WG_CONF="${RELAY_WG_DIR}/${RELAY_WG_IF}.conf"
RELAY_SERVER_ADDR="${RELAY_SERVER_ADDR:-10.250.0.1/24}"
RELAY_NODE_ADDR="${RELAY_NODE_ADDR:-10.250.0.2/24}"
RELAY_SERVER_IP="10.250.0.1"
RELAY_NODE_IP="${RELAY_NODE_IP:-10.250.0.2}"
RELAY_WG_PORT_DEFAULT=51820
RELAY_NODES_FILE="${BASE_DIR}/relay-nodes.conf"   # label|node_ip|public_key|port_min|port_max
RELAY_SLICE_SIZE="${RELAY_SLICE_SIZE:-5000}"      # jumlah port publik per node (default saat node-add)

relay_package_manager() {
  command -v apt-get >/dev/null 2>&1 && { echo apt; return; }
  command -v dnf >/dev/null 2>&1 && { echo dnf; return; }
  command -v yum >/dev/null 2>&1 && { echo yum; return; }
  command -v zypper >/dev/null 2>&1 && { echo zypper; return; }
  command -v apk >/dev/null 2>&1 && { echo apk; return; }
  echo unknown
}

relay_install_wireguard() {
  command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 && return 0

  local pm
  pm=$(relay_package_manager)
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || return 1
      apt-get install -y wireguard-tools iptables iproute2 >/dev/null 2>&1 || return 1
      ;;
    dnf)
      dnf install -y wireguard-tools iptables iproute >/dev/null 2>&1 || return 1
      ;;
    yum)
      yum install -y wireguard-tools iptables iproute >/dev/null 2>&1 || return 1
      ;;
    zypper)
      zypper --non-interactive install wireguard-tools iptables iproute2 >/dev/null 2>&1 || return 1
      ;;
    apk)
      apk add --no-cache wireguard-tools iptables iproute2 >/dev/null 2>&1 || return 1
      ;;
    *)
      return 1
      ;;
  esac

  command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1
}

relay_keypair() {
  local file="$1" pubfile="${2:-}"
  umask 077
  if [[ ! -s "$file" ]]; then
    wg genkey > "$file" || return 1
  fi
  chmod 600 "$file"
  if [[ -n "$pubfile" ]]; then
    wg pubkey < "$file" > "$pubfile" || return 1
    chmod 644 "$pubfile"
  fi
}

relay_endpoint_host() {
  local endpoint="$1"
  if [[ "$endpoint" == \[*\]:* ]]; then
    echo "${endpoint#\[}" | sed 's/\]:[0-9]*$//'
  elif [[ "$endpoint" == *:* ]]; then
    echo "${endpoint%:*}"
  else
    echo "$endpoint"
  fi
}

relay_endpoint_port() {
  local endpoint="$1"
  if [[ "$endpoint" == \[*\]:* ]]; then
    echo "${endpoint##*:}"
  elif [[ "$endpoint" == *:* ]]; then
    echo "${endpoint##*:}"
  else
    echo "$RELAY_WG_PORT_DEFAULT"
  fi
}

# Aturan iptables satu node di relay. Dipakai untuk PostUp/PostDown di config (op A/D, iface %i)
# maupun untuk menerapkan/menghapus langsung saat node ditambah/dihapus tanpa restart tunnel.
relay_node_iptables() {
  local op="$1" iface="$2" ip="$3" a="$4" b="$5" p
  for p in tcp udp; do
    echo "iptables -t nat -${op} PREROUTING -m addrtype --dst-type LOCAL -p ${p} --dport ${a}:${b} -j DNAT --to-destination ${ip}"
  done
  for p in tcp udp; do
    echo "iptables -${op} FORWARD -p ${p} -d ${ip} --dport ${a}:${b} -j ACCEPT"
  done
  echo "iptables -t nat -${op} POSTROUTING -o ${iface} -d ${ip} -j MASQUERADE"
}

relay_render_server_config() {
  local wg_port="$1" priv="$2" label ip pub a b line
  printf '[Interface]\nAddress = %s\nListenPort = %s\nPrivateKey = %s\n\n' "$RELAY_SERVER_ADDR" "$wg_port" "$priv"
  echo "PostUp = iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  echo "PostUp = iptables -A INPUT -p udp --dport ${wg_port} -j ACCEPT"
  echo "PostDown = iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  echo "PostDown = iptables -D INPUT -p udp --dport ${wg_port} -j ACCEPT"
  [[ -s "$RELAY_NODES_FILE" ]] || return 0
  while IFS='|' read -r label ip pub a b; do
    [[ -n "$label" ]] || continue
    echo
    echo "# node ${label}: ${a}-${b} -> ${ip}"
    while IFS= read -r line; do echo "PostUp = ${line}"; done < <(relay_node_iptables A '%i' "$ip" "$a" "$b")
    while IFS= read -r line; do echo "PostDown = ${line}"; done < <(relay_node_iptables D '%i' "$ip" "$a" "$b")
  done < "$RELAY_NODES_FILE"
  while IFS='|' read -r label ip pub a b; do
    [[ -n "$label" ]] || continue
    printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$label" "$pub" "$ip"
  done < "$RELAY_NODES_FILE"
}

relay_write_conf() {
  local port priv tmp
  port=$(conf_get RELAY_WG_PORT); port="${port:-$RELAY_WG_PORT_DEFAULT}"
  priv=$(cat "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key") || return 1
  mkdir -p "$RELAY_WG_DIR"; chmod 700 "$RELAY_WG_DIR"
  tmp="${RELAY_WG_CONF}.tmp.$$"
  ( umask 077; relay_render_server_config "$port" "$priv" > "$tmp" ) && chmod 600 "$tmp" && mv -f "$tmp" "$RELAY_WG_CONF" || { rm -f "$tmp"; return 1; }
}

relay_is_up() { systemctl is-active --quiet "wg-quick@${RELAY_WG_IF}.service"; }

# Pastikan relay sudah di-init dan memakai registry multi-node.
relay_ready() {
  if [[ ! -f "$RELAY_WG_CONF" || ! -f "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key" ]]; then
    err "Relay belum di-init. Jalankan: vpsnat relay init"; return 1
  fi
  [[ -f "$RELAY_NODES_FILE" ]] && return 0
  if grep -q '^\[Peer\]' "$RELAY_WG_CONF"; then
    err "Relay ini dibuat dengan mode lama (1 node, seluruh range). Untuk multi-node: vpsnat relay detach, lalu vpsnat relay init ulang."
    return 1
  fi
  # Relay lama tanpa node: pindah ke registry; aturan lama (seluruh range ke satu IP) harus dilepas.
  ( umask 077; : > "$RELAY_NODES_FILE" )
  if relay_is_up; then
    systemctl stop "wg-quick@${RELAY_WG_IF}.service" || true
    relay_write_conf || return 1
    systemctl start "wg-quick@${RELAY_WG_IF}.service" || return 1
  else
    relay_write_conf || return 1
  fi
}

relay_next_ip() {
  local n ip used
  used=$(cut -d'|' -f2 "$RELAY_NODES_FILE" 2>/dev/null || true)
  for n in $(seq 2 254); do
    ip="10.250.0.${n}"
    grep -qx "$ip" <<< "$used" || { echo "$ip"; return 0; }
  done
  return 1
}

relay_next_slice() {
  local size="$1" start="$PORT_MIN" a b
  while IFS='|' read -r _ _ _ a b; do
    [[ -n "$a" ]] || continue
    (( start + size - 1 < a )) && break
    (( b + 1 > start )) && start=$((b + 1))
  done < <(sort -t'|' -k4,4n "$RELAY_NODES_FILE" 2>/dev/null || true)
  (( start + size - 1 <= PORT_MAX )) || return 1
  echo "${start}-$((start + size - 1))"
}

relay_range_check() {
  local a="$1" b="$2" ra rb
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || { err "Range port harus berbentuk MIN-MAX (angka)."; return 1; }
  (( a >= PORT_MIN && b <= PORT_MAX && a <= b )) || { err "Range harus di dalam ${PORT_MIN}-${PORT_MAX}."; return 1; }
  (( b - a + 1 >= 100 )) || { err "Range minimal 100 port."; return 1; }
  while IFS='|' read -r _ _ _ ra rb; do
    [[ -n "$ra" ]] || continue
    (( b < ra || a > rb )) || { err "Range ${a}-${b} bentrok dengan node lain (${ra}-${rb})."; return 1; }
  done < "$RELAY_NODES_FILE"
}

relay_register_node() {
  local label="$1" ip="$2" pub="$3" a="$4" b="$5" line
  printf '%s|%s|%s|%s|%s\n' "$label" "$ip" "$pub" "$a" "$b" >> "$RELAY_NODES_FILE"
  relay_write_conf || { sed -i '$d' "$RELAY_NODES_FILE"; err "Gagal menulis config WireGuard."; return 1; }
  if relay_is_up; then
    wg set "$RELAY_WG_IF" peer "$pub" allowed-ips "${ip}/32" || { err "Gagal menambahkan peer WireGuard."; return 1; }
    while IFS= read -r line; do $line || true; done < <(relay_node_iptables A "$RELAY_WG_IF" "$ip" "$a" "$b")
  else
    systemctl enable --now "wg-quick@${RELAY_WG_IF}.service" || { err "Gagal start WireGuard relay."; return 1; }
  fi
}

relay_server_init() {
  need_root
  relay_install_wireguard || { err "Gagal memasang wireguard-tools. OS/package manager tidak didukung atau paket gagal."; return 1; }

  local pub_ip wg_port priv pub
  [[ ! -f "$RELAY_WG_CONF" ]] || { err "${RELAY_WG_CONF} sudah ada. Gunakan relay status atau hapus config jika ingin inisialisasi ulang."; return 1; }
  pub_ip=$(pub_ip)
  [[ -n "$pub_ip" ]] || { err "Public IPv4 tidak terdeteksi."; return 1; }
  wg_port="${RELAY_WG_PORT:-$RELAY_WG_PORT_DEFAULT}"
  [[ "$wg_port" =~ ^[0-9]+$ ]] && (( wg_port >= 1 && wg_port <= 65535 )) || { err "RELAY_WG_PORT invalid."; return 1; }

  mkdir -p "$RELAY_WG_DIR"
  relay_keypair "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key"
  priv=$(cat "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key")
  pub=$(printf '%s\n' "$priv" | wg pubkey)
  conf_set RELAY_WG_PORT "$wg_port"
  ( umask 077; : > "$RELAY_NODES_FILE" )
  relay_write_conf || { err "Gagal menulis config WireGuard."; return 1; }

  cat > /etc/sysctl.d/99-vpsnat-relay.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  systemctl enable --now "wg-quick@${RELAY_WG_IF}.service" || { err "Gagal start WireGuard relay."; return 1; }
  conf_set RELAY_ROLE server
  conf_set RELAY_SERVER_IP "$pub_ip"
  conf_set NETWORK_MODE direct

  ok "Relay aktif: ${pub_ip}:${wg_port}/udp"
  info "WireGuard public key: ${pub}"
  info "Tambah node (bisa banyak): vpsnat relay node-add <label>"
}

# Satu langkah di relay: buat peer + keypair node, alokasikan IP tunnel dan slice port,
# lalu cetak token untuk ditempel di node (vpsnat relay join <token>).
relay_node_add() {
  need_root
  relay_ready || return 1
  local label="${1:-}" range="${2:-}" a b ip priv pub relay_pub endpoint token
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Pakai: vpsnat relay node-add <label> [port-min-port-max]  (label: a-z0-9-)"; return 1; }
  awk -F'|' -v n="$label" '$1==n{f=1} END{exit !f}' "$RELAY_NODES_FILE" && { err "Node '${label}' sudah terdaftar."; return 1; }
  if [[ -z "$range" ]]; then
    range=$(relay_next_slice "$RELAY_SLICE_SIZE") || { err "Range port publik sudah penuh. Hapus node atau beri range lebih kecil."; return 1; }
  fi
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || { err "Range harus berbentuk MIN-MAX, mis. 20000-24999."; return 1; }
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  relay_range_check "$a" "$b" || return 1
  ip=$(relay_next_ip) || { err "IP tunnel habis."; return 1; }
  priv=$(wg genkey) || { err "wg genkey gagal."; return 1; }
  pub=$(printf '%s\n' "$priv" | wg pubkey)
  relay_register_node "$label" "$ip" "$pub" "$a" "$b" || return 1

  relay_pub=$(wg pubkey < "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key")
  endpoint="$(conf_get RELAY_SERVER_IP):$(conf_get RELAY_WG_PORT)"
  token=$(printf 'v1|%s|%s|%s|%s|%s|%s|%s' "$endpoint" "$relay_pub" "$ip" "$a" "$b" "$priv" "$label" | base64 | tr -d '\n')
  ok "Node '${label}' terdaftar: ${ip}, port publik ${a}-${b}."
  info "Jalankan di NODE '${label}' (sekali pakai, token memuat private key: jangan dibagikan):"
  echo
  echo "  vpsnat relay join ${token}"
  echo
  info "Firewall provider relay: UDP ${RELAY_WG_PORT:-$(conf_get RELAY_WG_PORT)} dan TCP/UDP ${a}-${b}."
}

# Manual: node membuat keypair sendiri (vpsnat relay attach), lalu public key didaftarkan di sini.
relay_peer_add() {
  need_root
  relay_ready || return 1
  local node_ip="${1:-10.250.0.2}" node_pub="${2:-}" range="${3:-}" label="${4:-}" a b
  [[ "$node_ip" =~ ^10\.250\.0\.[0-9]{1,3}$ ]] || { err "IP node harus IP tunnel 10.250.0.x."; return 1; }
  [[ "$node_pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { err "Public key WireGuard node invalid."; return 1; }
  if grep -qF "|${node_pub}|" "$RELAY_NODES_FILE"; then ok "Peer node sudah terdaftar."; return 0; fi
  cut -d'|' -f2 "$RELAY_NODES_FILE" | grep -qx "$node_ip" && { err "IP ${node_ip} sudah dipakai node lain."; return 1; }
  [[ -n "$label" ]] || label="node${node_ip##*.}"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Label tidak valid (a-z0-9-)."; return 1; }
  awk -F'|' -v n="$label" '$1==n{f=1} END{exit !f}' "$RELAY_NODES_FILE" && { err "Label '${label}' sudah dipakai."; return 1; }
  if [[ -z "$range" ]]; then
    range=$(relay_next_slice "$RELAY_SLICE_SIZE") || { err "Range port publik sudah penuh."; return 1; }
  fi
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || { err "Range harus berbentuk MIN-MAX."; return 1; }
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  relay_range_check "$a" "$b" || return 1
  relay_register_node "$label" "$node_ip" "$node_pub" "$a" "$b" || return 1
  ok "Peer '${label}' ${node_ip} terdaftar, port publik ${a}-${b}."
  info "Di node, batasi alokasi port ke slice ini: vpsnat relay slice ${a}-${b}"
}

relay_node_list() {
  [[ -s "$RELAY_NODES_FILE" ]] || { echo "(belum ada node terdaftar)"; return 0; }
  local hs now label ip pub a b ts state
  hs=$(wg show "$RELAY_WG_IF" latest-handshakes 2>/dev/null || true)
  now=$(date +%s)
  printf '%-16s %-14s %-13s %s\n' LABEL IP_TUNNEL PORT_PUBLIK STATUS
  while IFS='|' read -r label ip pub a b; do
    [[ -n "$label" ]] || continue
    ts=$(awk -v k="$pub" '$1==k{print $2}' <<< "$hs")
    if [[ "${ts:-0}" =~ ^[0-9]+$ ]] && (( ts > 0 && now - ts < 180 )); then state="terhubung"; else state="belum terhubung"; fi
    printf '%-16s %-14s %-13s %s\n' "$label" "$ip" "${a}-${b}" "$state"
  done < "$RELAY_NODES_FILE"
}

relay_node_del() {
  need_root
  relay_ready || return 1
  local label="${1:-}" row ip pub a b line tmp
  [[ -n "$label" ]] || { relay_node_list; err "Pakai: vpsnat relay node-del <label>"; return 1; }
  row=$(awk -F'|' -v n="$label" '$1==n{print; exit}' "$RELAY_NODES_FILE")
  [[ -n "$row" ]] || { err "Node '${label}' tidak ditemukan."; return 1; }
  IFS='|' read -r _ ip pub a b <<< "$row"
  if relay_is_up; then
    while IFS= read -r line; do $line >/dev/null 2>&1 || true; done < <(relay_node_iptables D "$RELAY_WG_IF" "$ip" "$a" "$b")
    wg set "$RELAY_WG_IF" peer "$pub" remove 2>/dev/null || true
  fi
  tmp=$(mktemp)
  awk -F'|' -v n="$label" '$1!=n' "$RELAY_NODES_FILE" > "$tmp" && cat "$tmp" > "$RELAY_NODES_FILE"; rm -f "$tmp"
  relay_write_conf || return 1
  ok "Node '${label}' dihapus dari relay (${ip}, ${a}-${b})."
  info "Di node tersebut jalankan: vpsnat relay detach"
}

relay_node_attach() {
  need_root
  local endpoint="${1:-}" relay_pub="${2:-}" node_ip="${3:-10.250.0.2}"
  [[ -n "$endpoint" && -n "$relay_pub" ]] || { err "Pakai: vpsnat relay attach <relay-ip:port> <relay-public-key> [10.250.0.2]"; return 1; }
  [[ "$relay_pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { err "Public key relay invalid."; return 1; }
  [[ "$node_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "IP tunnel node invalid."; return 1; }
  relay_install_wireguard || { err "Gagal memasang wireguard-tools."; return 1; }

  mkdir -p "$RELAY_WG_DIR"
  chmod 700 "$RELAY_WG_DIR"
  if [[ -f "$RELAY_WG_CONF" ]]; then
    err "${RELAY_WG_CONF} sudah ada. Jalankan 'vpsnat relay detach' dulu jika ingin mengganti relay."; return 1
  fi

  local priv pub relay_host relay_port
  if [[ -n "${RELAY_JOIN_PRIV:-}" ]]; then
    ( umask 077; printf '%s\n' "$RELAY_JOIN_PRIV" > "${RELAY_WG_DIR}/${RELAY_WG_IF}.client.key" )
  fi
  relay_keypair "${RELAY_WG_DIR}/${RELAY_WG_IF}.client.key"
  priv=$(cat "${RELAY_WG_DIR}/${RELAY_WG_IF}.client.key")
  pub=$(printf '%s\n' "$priv" | wg pubkey)
  relay_host=$(relay_endpoint_host "$endpoint")
  relay_port=$(relay_endpoint_port "$endpoint")

  cat > "$RELAY_WG_CONF" <<EOF2
[Interface]
Address = ${node_ip}/24
PrivateKey = ${priv}

[Peer]
PublicKey = ${relay_pub}
Endpoint = ${relay_host}:${relay_port}
AllowedIPs = 10.250.0.0/24
PersistentKeepalive = 25
EOF2
  chmod 600 "$RELAY_WG_CONF"

  cat > /etc/sysctl.d/99-vpsnat-relay-node.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  systemctl enable --now "wg-quick@${RELAY_WG_IF}.service" || { rm -f "$RELAY_WG_CONF"; err "Gagal start WireGuard client."; return 1; }
  conf_set NETWORK_MODE relay
  conf_set RELAY_ENDPOINT "$endpoint"
  conf_set RELAY_SERVER_PUBLIC_KEY "$relay_pub"
  conf_set RELAY_NODE_IP "$node_ip"

  ok "Node terhubung ke relay ${endpoint}."
  if [[ -z "${RELAY_JOIN_PRIV:-}" ]]; then
    info "Public key node: ${pub}"
    info "Jalankan di relay: vpsnat relay peer-add ${node_ip} ${pub}"
    info "Setelah peer didaftarkan, public port ${PORT_MIN}-${PORT_MAX} akan diteruskan ke node."
  fi
}

# Batasi alokasi port VPS di node ini ke satu slice (dibaca core.sh). Kosong/"off" = range penuh.
relay_node_slice() {
  need_root
  local range="${1:-}" a b
  if [[ -z "$range" || "$range" == "off" ]]; then
    conf_set NODE_PORT_MIN ""; conf_set NODE_PORT_MAX ""
    ok "Slice port dimatikan; alokasi memakai ${PORT_MIN}-${PORT_MAX} (berlaku di perintah berikutnya)."
    return 0
  fi
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || { err "Pakai: vpsnat relay slice <MIN-MAX|off>"; return 1; }
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  (( a >= 1024 && b <= 65535 && a <= b )) || { err "Range tidak valid."; return 1; }
  conf_set NODE_PORT_MIN "$a"; conf_set NODE_PORT_MAX "$b"
  ok "Alokasi port VPS di node ini dibatasi ke ${a}-${b}."
}

# Satu langkah di node: tempel token dari `vpsnat relay node-add` di relay.
relay_node_join() {
  need_root
  local token="${1:-}" payload ver endpoint relay_pub node_ip a b priv label host outside
  [[ -n "$token" ]] || { err "Pakai: vpsnat relay join <token dari: vpsnat relay node-add <label> di relay>"; return 1; }
  payload=$(printf '%s' "$token" | base64 -d 2>/dev/null) || { err "Token tidak valid."; return 1; }
  IFS='|' read -r ver endpoint relay_pub node_ip a b priv label <<< "$payload"
  [[ "$ver" == "v1" ]] || { err "Token tidak valid atau versi tidak didukung."; return 1; }
  [[ "$endpoint" =~ ^[][A-Za-z0-9.:-]+$ ]] || { err "Endpoint relay di token tidak valid."; return 1; }
  [[ "$relay_pub" =~ ^[A-Za-z0-9+/]{43}=$ && "$priv" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { err "Key di token tidak valid."; return 1; }
  [[ "$node_ip" =~ ^10\.250\.0\.[0-9]{1,3}$ ]] || { err "IP tunnel di token tidak valid."; return 1; }
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && (( a <= b )) || { err "Range port di token tidak valid."; return 1; }
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { err "Label di token tidak valid."; return 1; }
  if [[ -s "$DB_FILE" ]]; then
    outside=$(awk -F'|' -v a="$a" -v b="$b" '$3+0<a || $3+0>b{c++} END{print c+0}' "$DB_FILE")
    if (( outside > 0 )); then
      warn "${outside} VPS di node ini memakai port SSH di luar ${a}-${b}; port itu tidak akan diteruskan relay."
      confirm "Tetap gabung ke relay?" || return 1
    fi
  fi
  RELAY_JOIN_PRIV="$priv" relay_node_attach "$endpoint" "$relay_pub" "$node_ip" || return 1
  conf_set RELAY_PREV_PUBLIC_IP "$(conf_get PUBLIC_IP)"
  conf_set RELAY_JOINED 1
  conf_set NODE_PORT_MIN "$a"
  conf_set NODE_PORT_MAX "$b"
  conf_set NODE_LABEL "$label"
  host=$(relay_endpoint_host "$endpoint")
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && conf_set PUBLIC_IP "$host"
  ok "Node '${label}' bergabung. Port VPS dialokasikan di ${a}-${b}; IP publik untuk buyer: ${host}."
}

relay_detach() {
  need_root
  systemctl disable --now "wg-quick@${RELAY_WG_IF}.service" 2>/dev/null || true
  rm -f "$RELAY_WG_CONF" "${RELAY_WG_DIR}/${RELAY_WG_IF}.client.key"
  if [[ "$(conf_get RELAY_ROLE)" == "server" ]]; then
    rm -f "$RELAY_NODES_FILE"
    conf_set RELAY_ROLE ""
  fi
  if [[ "$(conf_get RELAY_JOINED)" == "1" ]]; then
    conf_set PUBLIC_IP "$(conf_get RELAY_PREV_PUBLIC_IP)"
    conf_set NODE_PORT_MIN ""
    conf_set NODE_PORT_MAX ""
    conf_set RELAY_JOINED 0
  fi
  conf_set NETWORK_MODE direct
  conf_set RELAY_ENDPOINT ""
  conf_set RELAY_SERVER_PUBLIC_KEY ""
  ok "Relay dilepas; mode kembali direct."
}

relay_ctl() {
  need_root
  local action="${1:-status}"
  case "$action" in
    on|start) systemctl enable --now "wg-quick@${RELAY_WG_IF}.service" && ok "WireGuard ${RELAY_WG_IF} ON." ;;
    off|stop) systemctl disable --now "wg-quick@${RELAY_WG_IF}.service" && ok "WireGuard ${RELAY_WG_IF} OFF." ;;
    restart) systemctl restart "wg-quick@${RELAY_WG_IF}.service" && ok "WireGuard ${RELAY_WG_IF} restarted." ;;
    logs) journalctl -u "wg-quick@${RELAY_WG_IF}" -n 80 --no-pager ;;
    status)
      echo "NETWORK_MODE : $(conf_get NETWORK_MODE || echo direct)"
      echo "RELAY_IF     : ${RELAY_WG_IF}"
      if [[ -f "$RELAY_WG_CONF" ]]; then
        wg show "$RELAY_WG_IF" 2>/dev/null || true
      else
        echo "WireGuard config belum ada."
      fi
      if [[ -f "$RELAY_NODES_FILE" ]]; then echo; relay_node_list; fi
      ;;
    *)
      err "Pakai: vpsnat relay [init|node-add|node-list|node-del|join|peer-add|attach|slice|detach|status|on|off|restart|logs]"
      return 1
      ;;
  esac
}

relay_dispatch() {
  case "${1:-status}" in
    init) shift; relay_server_init "$@" ;;
    node-add) shift; relay_node_add "$@" ;;
    node-list) shift; relay_node_list "$@" ;;
    node-del) shift; relay_node_del "$@" ;;
    join) shift; relay_node_join "$@" ;;
    slice) shift; relay_node_slice "$@" ;;
    peer-add) shift; relay_peer_add "$@" ;;
    attach) shift; relay_node_attach "$@" ;;
    detach) shift; relay_detach "$@" ;;
    status|on|start|off|stop|restart|logs) relay_ctl "$@" ;;
    *) err "Pakai: vpsnat relay [init|node-add|node-list|node-del|join|peer-add|attach|slice|detach|status|on|off|restart|logs]"; return 1 ;;
  esac
}
