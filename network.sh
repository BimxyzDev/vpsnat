#!/usr/bin/env bash

alloc_contiguous_ports() {
  local need="$1" p start=0 run=0
  [[ "$need" =~ ^[0-9]+$ ]] || return 1
  (( need >= 1 )) || return 1
  for p in $(seq "$SSH_BASE" "$PORT_MAX"); do
    if port_used "$p"; then
      run=0
      start=0
      continue
    fi
    (( run == 0 )) && start="$p"
    (( run += 1 ))
    if (( run >= need )); then
      echo "${start} $((start + need - 1))"
      return 0
    fi
  done
  return 1
}

alloc_ports() {
  local need="$1" range start end
  range=$(alloc_contiguous_ports "$need") || return 1
  read -r start end <<< "$range"
  seq "$start" "$end"
}

next_ip() {
  local used i
  used=$(cut -d'|' -f2 "$DB_FILE" 2>/dev/null)
  for i in $(seq 2 250); do
    if ! grep -qx "${NET_PREFIX}.${i}" <<<"$used"; then
      echo "${NET_PREFIX}.${i}"
      return 0
    fi
  done
  return 1
}

port_used() {
  local p="$1"
  if grep -qE "(^|[|,])(tcp|udp):${p}:" "$DB_FILE" 2>/dev/null; then
    return 0
  fi
  ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$"
}

ensure_net() {
  export PATH="$PATH:/snap/bin"
  local dns="dhcp-option=6,1.1.1.1,8.8.8.8"
  lxc network show "$BRIDGE" &>/dev/null || return 0
  [[ "$(lxc network get "$BRIDGE" ipv4.dhcp 2>/dev/null)" == "true" ]] || lxc network set "$BRIDGE" ipv4.dhcp true
  [[ "$(lxc network get "$BRIDGE" raw.dnsmasq 2>/dev/null)" == "$dns" ]] || lxc network set "$BRIDGE" raw.dnsmasq "$dns"
  lxc profile device unset "$PROFILE" root size &>/dev/null || true
}

init_lxd() {
  export PATH="$PATH:/snap/bin"
  if lxc network show "$BRIDGE" &>/dev/null && lxc storage show "$POOL" &>/dev/null; then
    ensure_net
    ok "LXD sudah terinisialisasi."
    return 0
  fi

  local pool_size driver
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    pool_size="${STORAGE_SIZE_GB:-50}"
  else
    read -rp "Ukuran storage pool total untuk semua VPS (GB) [50]: " pool_size
    pool_size=${pool_size:-50}
  fi
  [[ "$pool_size" =~ ^[0-9]+$ ]] || die "Ukuran storage harus angka."

  driver="dir"
  if command -v zpool &>/dev/null && modprobe zfs 2>/dev/null; then
    driver="zfs"
  elif command -v btrfs &>/dev/null && grep -qw btrfs /proc/filesystems; then
    driver="btrfs"
  fi
  info "Storage driver: ${driver}"
  conf_set STORAGE_DRIVER "$driver"

  if ! lxc storage show "$POOL" &>/dev/null; then
    case "$driver" in
      dir) lxc storage create "$POOL" dir || die "Gagal buat storage." ;;
      *)   lxc storage create "$POOL" "$driver" size="${pool_size}GB" || {
             warn "Driver ${driver} gagal, fallback ke dir."
             lxc storage create "$POOL" dir || die "Gagal buat storage."
             conf_set STORAGE_DRIVER dir
           } ;;
    esac
  fi

  if ! lxc network show "$BRIDGE" &>/dev/null; then
    lxc network create "$BRIDGE" \
      ipv4.address="$SUBNET" \
      ipv4.nat=false \
      ipv4.dhcp=true \
      ipv6.address=none \
      dns.mode=managed || die "Gagal buat bridge."
  fi

  lxc profile show "$PROFILE" &>/dev/null || lxc profile create "$PROFILE"
  lxc profile device remove "$PROFILE" root &>/dev/null || true
  lxc profile device remove "$PROFILE" eth0 &>/dev/null || true
  lxc profile device add "$PROFILE" root disk path=/ pool="$POOL"
  lxc profile device add "$PROFILE" eth0 nic network="$BRIDGE" name=eth0
  ensure_net
  ok "LXD siap."
}

fw_setup() {
  local iface
  iface=$(detect_iface)
  [[ -z "$iface" ]] && die "Interface publik tidak terdeteksi."

  iptables -t nat -N VPSNAT_PRE 2>/dev/null || true
  iptables -t nat -N VPSNAT_POST 2>/dev/null || true
  iptables -N VPSNAT_FWD 2>/dev/null || true

  iptables -t nat -C PREROUTING -j VPSNAT_PRE 2>/dev/null || iptables -t nat -A PREROUTING -j VPSNAT_PRE
  iptables -t nat -C OUTPUT -j VPSNAT_PRE 2>/dev/null || iptables -t nat -A OUTPUT -j VPSNAT_PRE
  iptables -t nat -C POSTROUTING -j VPSNAT_POST 2>/dev/null || iptables -t nat -A POSTROUTING -j VPSNAT_POST
  iptables -C FORWARD -j VPSNAT_FWD 2>/dev/null || iptables -I FORWARD 1 -j VPSNAT_FWD

  iptables -t nat -C VPSNAT_POST -s "${NET_PREFIX}.0/24" ! -d "${NET_PREFIX}.0/24" -o "$iface" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A VPSNAT_POST -s "${NET_PREFIX}.0/24" ! -d "${NET_PREFIX}.0/24" -o "$iface" -j MASQUERADE
  iptables -t nat -C VPSNAT_POST -s "${NET_PREFIX}.0/24" -d "${NET_PREFIX}.0/24" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A VPSNAT_POST -s "${NET_PREFIX}.0/24" -d "${NET_PREFIX}.0/24" -j MASQUERADE
  fw_save
}

fw_save() {
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || true
  else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
  fi
}

fw_add_forward() {
  local proto="$1" ext="$2" ip="$3" int="$4" p
  local protos=("$proto")
  [[ "$proto" == "both" ]] && protos=(tcp udp)
  for p in "${protos[@]}"; do
    iptables -t nat -C VPSNAT_PRE -p "$p" --dport "$ext" -j DNAT --to-destination "${ip}:${int}" 2>/dev/null || \
      iptables -t nat -A VPSNAT_PRE -p "$p" --dport "$ext" -j DNAT --to-destination "${ip}:${int}"
    iptables -C VPSNAT_FWD -p "$p" -d "$ip" --dport "$int" -j ACCEPT 2>/dev/null || \
      iptables -A VPSNAT_FWD -p "$p" -d "$ip" --dport "$int" -j ACCEPT
  done
}

fw_del_forward() {
  local proto="$1" ext="$2" ip="$3" int="$4" p
  local protos=("$proto")
  [[ "$proto" == "both" ]] && protos=(tcp udp)
  for p in "${protos[@]}"; do
    iptables -t nat -D VPSNAT_PRE -p "$p" --dport "$ext" -j DNAT --to-destination "${ip}:${int}" 2>/dev/null || true
    iptables -D VPSNAT_FWD -p "$p" -d "$ip" --dport "$int" -j ACCEPT 2>/dev/null || true
  done
}

apply_all_rules() {
  local name ip ports e proto ext int rest susp quota_susp
  fw_setup
  iptables -t nat -F VPSNAT_PRE
  iptables -F VPSNAT_FWD

  # Quota drops must be evaluated before the broad bridge ACCEPT rules.
  while IFS='|' read -r name ip _ _ _ _ _ _ _ _ _ _ susp _ _ _ _ _ quota_susp _ _ _ _ _ _ _; do
    [[ -z "$name" || -z "$ip" ]] && continue
    [[ "${susp:-0}" == "1" ]] && continue
    if [[ "${quota_susp:-0}" == "1" ]]; then
      iptables -A VPSNAT_FWD -s "$ip" -j DROP
      iptables -A VPSNAT_FWD -d "$ip" -j DROP
    fi
  done < "$DB_FILE"

  while IFS='|' read -r name ip _ _ _ _ ports _ _ _ _ _ susp _ _ _ _ _ quota_susp _ _ _ _ _ _ _; do
    [[ -z "$name" ]] && continue
    [[ "${susp:-0}" == "1" || "${quota_susp:-0}" == "1" ]] && continue
    [[ -z "$ports" || "$ports" == "-" ]] && continue
    for e in ${ports//,/ }; do
      proto=${e%%:*}
      rest=${e#*:}
      ext=${rest%%:*}
      int=${rest#*:}
      fw_add_forward "$proto" "$ext" "$ip" "$int"
    done
  done < "$DB_FILE"

  iptables -A VPSNAT_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A VPSNAT_FWD -i "$BRIDGE" -j ACCEPT
  iptables -A VPSNAT_FWD -o "$BRIDGE" -j ACCEPT
  fw_save
}

set_static_ip() {
  local name="$1" ip="$2" out
  out=$(lxc config device override "$name" eth0 ipv4.address="$ip" 2>&1) && return 0
  lxc config device set "$name" eth0 ipv4.address "$ip" 2>/dev/null && return 0
  warn "Gagal set IP ${ip}: ${out}"
  return 1
}

next_ssh_port() {
  local p
  for p in $(seq "$SSH_BASE" "$PORT_MAX"); do
    if ! port_used "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

image_for() {
  case "$1" in
    ubuntu22|u22) echo "ubuntu:22.04" ;;
    ubuntu24|u24) echo "ubuntu:24.04" ;;
    ubuntu20|u20) echo "ubuntu:20.04" ;;
    debian12|d12) echo "images:debian/12" ;;
    debian11|d11) echo "images:debian/11" ;;
    alma9|a9)     echo "images:almalinux/9" ;;
    rocky9|r9)    echo "images:rockylinux/9" ;;
    alpine|alp)   echo "images:alpine/3.19" ;;
    *)            echo "$1" ;;
  esac
}

gen_pass() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16
}

wait_ip() {
  local name="$1" ip="$2" i
  for i in $(seq 1 60); do
    lxc list "$name" -c 4 --format csv 2>/dev/null | grep -q "$ip" && return 0
    sleep 2
  done
  warn "Guest belum dapat IP ${ip}."
  return 1
}

wait_guest() {
  local name="$1" i
  for i in $(seq 1 60); do
    lxc exec "$name" -- true &>/dev/null && return 0
    sleep 2
  done
  return 1
}

setup_guest() {
  local name="$1" pass="$2" i
  info "Setup guest (SSH, root password)..."
  wait_guest "$name" || warn "Guest belum responsif, lanjut."
  for i in $(seq 1 30); do
    lxc exec "$name" -- ping -c1 -W1 1.1.1.1 &>/dev/null && break
    sleep 1
  done
  lxc exec "$name" -- sh -c '
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1
      apt-get install -y openssh-server curl wget nano sudo ca-certificates >/dev/null 2>&1
      systemctl enable ssh >/dev/null 2>&1; systemctl restart ssh >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y openssh-server curl wget nano sudo >/dev/null 2>&1
      systemctl enable --now sshd >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache openssh curl wget nano sudo bash >/dev/null 2>&1
      rc-update add sshd default >/dev/null 2>&1; rc-service sshd restart >/dev/null 2>&1
    fi
  '
  printf 'root:%s\n' "$pass" | lxc exec "$name" -- chpasswd
  lxc exec "$name" -- sh -c '
    f=/etc/ssh/sshd_config
    [ -f "$f" ] || exit 0
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" "$f"
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" "$f"
    [ -d /etc/ssh/sshd_config.d ] && rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || rc-service sshd restart 2>/dev/null
  '
}
