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

relay_write_server_config() {
  local priv="$1" wg_port="$2" node_ip="$3"
  local pmin="$PORT_MIN" pmax="$PORT_MAX"
  mkdir -p "$RELAY_WG_DIR"
  chmod 700 "$RELAY_WG_DIR"
  cat > "$RELAY_WG_CONF" <<EOF2
[Interface]
Address = ${RELAY_SERVER_ADDR}
ListenPort = ${wg_port}
PrivateKey = ${priv}

# Forward the complete VPSNAT public range to the attached node.
PostUp = iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport ${pmin}:${pmax} -j DNAT --to-destination ${node_ip}
PostUp = iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -p udp --dport ${pmin}:${pmax} -j DNAT --to-destination ${node_ip}
PostUp = iptables -A FORWARD -p tcp -d ${node_ip} --dport ${pmin}:${pmax} -j ACCEPT
PostUp = iptables -A FORWARD -p udp -d ${node_ip} --dport ${pmin}:${pmax} -j ACCEPT
PostUp = iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -d ${node_ip} -j MASQUERADE
PostUp = iptables -A INPUT -p udp --dport ${wg_port} -j ACCEPT

PostDown = iptables -t nat -D PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport ${pmin}:${pmax} -j DNAT --to-destination ${node_ip}
PostDown = iptables -t nat -D PREROUTING -m addrtype --dst-type LOCAL -p udp --dport ${pmin}:${pmax} -j DNAT --to-destination ${node_ip}
PostDown = iptables -D FORWARD -p tcp -d ${node_ip} --dport ${pmin}:${pmax} -j ACCEPT
PostDown = iptables -D FORWARD -p udp -d ${node_ip} --dport ${pmin}:${pmax} -j ACCEPT
PostDown = iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o %i -d ${node_ip} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${wg_port} -j ACCEPT
EOF2
  chmod 600 "$RELAY_WG_CONF"
}

relay_server_init() {
  need_root
  relay_install_wireguard || { err "Gagal memasang wireguard-tools. OS/package manager tidak didukung atau paket gagal."; return 1; }

  local pub_ip wg_port priv pub node_ip
  [[ ! -f "$RELAY_WG_CONF" ]] || { err "${RELAY_WG_CONF} sudah ada. Gunakan relay status atau hapus config jika ingin inisialisasi ulang."; return 1; }
  pub_ip=$(pub_ip)
  [[ -n "$pub_ip" ]] || { err "Public IPv4 tidak terdeteksi."; return 1; }
  wg_port="${RELAY_WG_PORT:-$RELAY_WG_PORT_DEFAULT}"
  [[ "$wg_port" =~ ^[0-9]+$ ]] && (( wg_port >= 1 && wg_port <= 65535 )) || { err "RELAY_WG_PORT invalid."; return 1; }
  node_ip="${RELAY_NODE_IP:-10.250.0.2}"

  mkdir -p "$RELAY_WG_DIR"
  relay_keypair "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key"
  priv=$(cat "${RELAY_WG_DIR}/${RELAY_WG_IF}.server.key")
  pub=$(printf '%s\n' "$priv" | wg pubkey)
  relay_write_server_config "$priv" "$wg_port" "$node_ip"

  cat > /etc/sysctl.d/99-vpsnat-relay.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  systemctl enable --now "wg-quick@${RELAY_WG_IF}.service" || { err "Gagal start WireGuard relay."; return 1; }
  conf_set RELAY_ROLE server
  conf_set RELAY_SERVER_IP "$pub_ip"
  conf_set RELAY_WG_PORT "$wg_port"
  conf_set RELAY_NODE_IP "$node_ip"
  conf_set NETWORK_MODE direct

  ok "Relay server aktif: ${pub_ip}:${wg_port}/udp"
  info "WireGuard public key: ${pub}"
  info "Range public: ${PORT_MIN}-${PORT_MAX} TCP/UDP → ${node_ip}"
  info "Di node: vpsnat relay attach ${pub_ip}:${wg_port} ${pub}"
}

relay_peer_add() {
  need_root
  local node_ip="${1:-${RELAY_NODE_IP:-10.250.0.2}}" node_pub="${2:-}" conf node_key
  [[ "$node_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "IP node invalid."; return 1; }
  [[ "$node_pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { err "Public key WireGuard node invalid."; return 1; }
  [[ -f "$RELAY_WG_CONF" ]] || { err "Relay belum di-init. Jalankan: vpsnat relay init"; return 1; }
  systemctl is-active --quiet "wg-quick@${RELAY_WG_IF}.service" || systemctl start "wg-quick@${RELAY_WG_IF}.service"

  conf=$(cat "$RELAY_WG_CONF")
  if grep -qF "PublicKey = ${node_pub}" <<< "$conf"; then
    ok "Peer node sudah terdaftar."
    return 0
  fi

  if grep -q '^\[Peer\]' <<< "$conf"; then
    err "Relay ini hanya mendukung satu NAT node per relay."; return 1
  fi

  cat >> "$RELAY_WG_CONF" <<EOF2

[Peer]
PublicKey = ${node_pub}
AllowedIPs = ${node_ip}/32
EOF2
  chmod 600 "$RELAY_WG_CONF"
  wg set "$RELAY_WG_IF" peer "$node_pub" allowed-ips "${node_ip}/32" || { err "Gagal menambahkan peer WireGuard."; return 1; }
  conf_set RELAY_NODE_IP "$node_ip"
  ok "Peer ${node_ip} terdaftar."
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
  info "Public key node: ${pub}"
  info "Jalankan di relay: vpsnat relay peer-add ${node_ip} ${pub}"
  info "Setelah peer didaftarkan, public port ${PORT_MIN}-${PORT_MAX} akan diteruskan ke node."
}

relay_detach() {
  need_root
  systemctl disable --now "wg-quick@${RELAY_WG_IF}.service" 2>/dev/null || true
  rm -f "$RELAY_WG_CONF" "${RELAY_WG_DIR}/${RELAY_WG_IF}.client.key"
  conf_set NETWORK_MODE direct
  conf_set RELAY_ENDPOINT ""
  conf_set RELAY_SERVER_PUBLIC_KEY ""
  ok "Relay node dilepas; mode kembali direct."
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
      ;;
    *)
      err "Pakai: vpsnat relay [init|peer-add|attach|detach|status|on|off|restart|logs]"
      return 1
      ;;
  esac
}

relay_dispatch() {
  case "${1:-status}" in
    init) shift; relay_server_init "$@" ;;
    peer-add) shift; relay_peer_add "$@" ;;
    attach) shift; relay_node_attach "$@" ;;
    detach) shift; relay_detach "$@" ;;
    status|on|start|off|stop|restart|logs) relay_ctl "$@" ;;
    *) err "Pakai: vpsnat relay [init|peer-add|attach|detach|status|on|off|restart|logs]"; return 1 ;;
  esac
}
