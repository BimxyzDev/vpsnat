#!/usr/bin/env bash

set -uo pipefail

VERSION="3.1.0"
APP_NAME="vpsnat"
BASE_DIR="${VPSNAT_BASE_DIR:-/etc/vpsnat}"
DB_FILE="${BASE_DIR}/vps.db"
CONF_FILE="${BASE_DIR}/vpsnat.conf"
LOCK_FILE="${BASE_DIR}/.db.lock"
LOG_FILE="${VPSNAT_LOG_FILE:-/var/log/vpsnat.log}"
NOTIF_DIR="${BASE_DIR}/.notif"
MONITOR_DIR="${BASE_DIR}/monitor"
BANDWIDTH_DIR="${BASE_DIR}/bandwidth"

BRIDGE="lxdbr0"
SUBNET="10.10.10.1/24"
NET_PREFIX="10.10.10"
POOL="vpsnat"
PROFILE="vpsnat"
PORT_MIN=20000
PORT_MAX=59999
SSH_BASE=20000
VPS_PORTS_MIN=2
VPS_PORTS_MAX=10

BIN_PATH="/usr/local/bin/vpsnat"
INSTALL_DIR="/usr/local/lib/vpsnat"
BOT_DIR="${BASE_DIR}/bot"
BOT_SERVICE="vpsnat-bot"
EXPIRE_TIMER="vpsnat-expire"
MONITOR_SERVICE="vpsnat-monitor"
GRACE_DAYS_DEFAULT=3
SHARED_SUSPEND_MINUTES_DEFAULT=60
RESOURCE_SAMPLE_SECONDS_DEFAULT=15
RESOURCE_THRESHOLD_DEFAULT=100
BANDWIDTH_DEFAULT_RATE_MBIT=0
BANDWIDTH_DEFAULT_QUOTA_GB=0
NETWORK_MODE_DEFAULT="direct"

NONINTERACTIVE="${VPSNAT_NONINTERACTIVE:-0}"

if [[ "$NONINTERACTIVE" == "1" || ! -t 1 ]]; then
  R=""; G=""; Y=""; B=""; C=""; W=""; N=""
else
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'
fi

log()  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "${C}[i]${N} $*"; }
ok()   { echo -e "${G}[+]${N} $*"; log "OK: $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*" >&2; log "ERR: $*"; }
die()  { err "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Jalankan sebagai root (sudo)."; }

pause() { [[ "$NONINTERACTIVE" == "1" ]] && return; echo; read -rp "Enter untuk lanjut..." _; }

confirm() {
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "${VPSNAT_YES:-0}" == "1" ]]
    return
  fi
  local a
  read -rp "$1 [y/N]: " a
  [[ "${a,,}" == "y" ]]
}

ask() {
  local __var="$1" __prompt="$2" __def="${3:-}" __in
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    __in="${!__var:-}"
  else
    read -rp "$__prompt" __in
  fi
  printf -v "$__var" '%s' "${__in:-$__def}"
}

with_lock() {
  mkdir -p "$BASE_DIR"
  exec 9>"$LOCK_FILE"
  flock -w 30 9 || { err "Gagal ambil lock DB."; return 1; }
  "$@"
  local rc=$?
  flock -u 9
  exec 9>&-
  return $rc
}

conf_get() {
  [[ -f "$CONF_FILE" ]] || return 0
  grep -E "^$1=" "$CONF_FILE" | tail -n1 | cut -d= -f2-
}

conf_set() {
  mkdir -p "$BASE_DIR"
  touch "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  if grep -q "^$1=" "$CONF_FILE"; then
    sed -i "s#^$1=.*#$1=$2#" "$CONF_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$CONF_FILE"
  fi
}

cfg_int() {
  local key="$1" fallback="$2" v
  v=$(conf_get "$key")
  [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  echo "$fallback"
}

ensure_runtime_dirs() {
  mkdir -p "$BASE_DIR" "$NOTIF_DIR" "$MONITOR_DIR" "$BANDWIDTH_DIR"
  touch "$DB_FILE" "$LOCK_FILE"
  chmod 600 "$DB_FILE" "$LOCK_FILE"
  touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || true
}

detect_iface() {
  local iface
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$iface" ]] && { echo "$iface"; return 0; }
  ip -4 route show default 2>/dev/null | awk 'NR==1{print $5; exit}'
}

detect_ip() {
  local ip iface
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  iface=$(detect_iface)
  [[ -n "$iface" ]] && ip -4 -o addr show dev "$iface" scope global | awk '{sub(/\/.*/,"",$4); print $4; exit}'
}

pub_ip() {
  local ip
  ip=$(conf_get PUBLIC_IP)
  [[ -z "$ip" ]] && ip=$(detect_ip)
  echo "$ip"
}

hw_virt_status() {
  local flags kvm_dev
  flags=$(grep -m1 -oE 'vmx|svm' /proc/cpuinfo 2>/dev/null | head -n1)
  [[ -e /dev/kvm ]] && kvm_dev=1 || kvm_dev=0
  if [[ -n "$flags" && "$kvm_dev" == "1" ]]; then
    echo "on"
  elif [[ -n "$flags" ]]; then
    echo "flag-only"
  else
    echo "off"
  fi
}

hw_virt_label() {
  case "$(hw_virt_status)" in
    on)        echo "${G}AKTIF (VM & container)${N}" ;;
    flag-only) echo "${Y}CPU support, /dev/kvm tidak ada (container-only)${N}" ;;
    *)         echo "${R}DISABLE (container-only)${N}" ;;
  esac
}

vm_supported() { [[ "$(hw_virt_status)" == "on" ]]; }

check_virt_env() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  info "Environment: ${virt}"
  case "$virt" in
    openvz|lxc|lxc-libvirt|wsl|proot|podman|docker)
      warn "Environment '${virt}' kemungkinan tidak mendukung LXD penuh (butuh kernel penuh & privilege)."
      confirm "Lanjut tetap?" || die "Dibatalkan."
      ;;
  esac
  local hv; hv=$(hw_virt_status)
  case "$hv" in
    on)        ok "VT-x/AMD-V aktif. Mode VM (KVM) tersedia."; conf_set VM_MODE yes ;;
    flag-only) warn "CPU punya vmx/svm tapi /dev/kvm tidak ada. Mode: container-only."; conf_set VM_MODE no ;;
    off)       warn "VT-x/AMD-V DISABLE. Mode: container-only (tanpa KVM)."; conf_set VM_MODE no ;;
  esac
}

install_deps() {
  need_root
  info "Update apt & install dependensi..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl iptables iproute2 openssl jq snapd bridge-utils util-linux python3 python3-venv python3-pip || die "Gagal install dependensi dasar."
  apt-get install -y iptables-persistent netfilter-persistent 2>/dev/null || warn "iptables-persistent gagal, pakai service restore vpsnat."
  apt-get install -y zfsutils-linux 2>/dev/null || warn "zfsutils-linux tidak tersedia, skip."
  apt-get install -y btrfs-progs xfsprogs 2>/dev/null || true
  if ! command -v lxc &>/dev/null && ! [[ -x /snap/bin/lxc ]]; then
    info "Install LXD via snap..."
    snap install lxd || die "Gagal install LXD."
    sleep 3
  fi
  export PATH="$PATH:/snap/bin"
  printf '%s\n' 'export PATH="$PATH:/snap/bin"' > /etc/profile.d/vpsnat.sh
}

enable_forward() {
  cat > /etc/sysctl.d/99-vpsnat.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.bridge.bridge-nf-call-iptables=1
net.netfilter.nf_conntrack_max=262144
vm.swappiness=10
SYSCTL
  modprobe br_netfilter 2>/dev/null || true
  echo br_netfilter > /etc/modules-load.d/vpsnat.conf
  sysctl --system >/dev/null 2>&1
}
