#!/usr/bin/env bash
# VPSNAT — bootstrap kompatibilitas install/update untuk instalasi lama.
#
#   curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/get.sh | sudo bash
#
# Model v4 memisahkan peran. Script ini memilih peran otomatis bila tidak
# ditentukan, supaya perintah lama tetap berjalan:
#   - sudah ada /etc/vpsnat/role  -> pakai peran itu
#   - ada LXD                     -> node
#   - selain itu                  -> panel
#
# Untuk pemasangan baru, pakai script peran yang eksplisit:
#   scripts/install-panel.sh   (control-plane: DB client, web panel, bot)
#   scripts/install-node.sh    (data-plane: LXD, NAT, agent)
#
# Opsi: --check, --force, --panel, --node
# Environment: VPSNAT_REPO, VPSNAT_BRANCH, VPSNAT_REF, VPSNAT_SKIP_TESTS

set -uo pipefail

vpsnat_get() {
  local role="" here src repo branch tmp rc
  local -a passthru=()
  while (($#)); do
    case "$1" in
      --panel) role="panel" ;;
      --node) role="node" ;;
      *) passthru+=("$1") ;;
    esac
    shift
  done
  if [[ -z "$role" ]]; then
    if [[ -r /etc/vpsnat/role ]]; then
      IFS= read -r role < /etc/vpsnat/role || true
    elif command -v lxc >/dev/null 2>&1 || [[ -x /snap/bin/lxc ]]; then
      role="node"
    else
      role="panel"
    fi
  fi
  [[ "$role" == "both" ]] && role="node"

  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")
  src="${here}/_bootstrap.sh"
  echo "[i] Peran terdeteksi: ${role}"
  if [[ ! -s "$src" ]]; then
    repo="${VPSNAT_REPO:-BimxyzDev/vpsnat}"; branch="${VPSNAT_BRANCH:-main}"
    tmp=$(mktemp -d) || { echo "[x] Tidak bisa membuat direktori sementara." >&2; return 1; }
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 \
      "https://raw.githubusercontent.com/${repo}/${branch}/scripts/_bootstrap.sh" -o "$tmp/_bootstrap.sh" \
      || { echo "[x] Gagal mengunduh scripts/_bootstrap.sh." >&2; rm -rf "$tmp"; return 1; }
    bash "$tmp/_bootstrap.sh" "$role" "${passthru[@]}"; rc=$?
    rm -rf "$tmp"
    return $rc
  fi
  bash "$src" "$role" "${passthru[@]}"
}

vpsnat_get "$@"; exit $?
