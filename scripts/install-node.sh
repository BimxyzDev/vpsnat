#!/usr/bin/env bash
# VPSNAT — pasang NODE (data-plane) dengan satu perintah.
#
#   curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/scripts/install-node.sh | sudo bash
#
# Node menjalankan SELURUH VPS client (LXD), NAT/port forwarding, bandwidth,
# monitor, expiry, dan agent HTTP yang melayani perintah panel — padanan `wings`
# Pterodactyl. Setelah selesai, daftarkan node ini dari PANEL memakai token yang
# dicetak di akhir instalasi.
#
# Opsi (environment):
#   VPSNAT_REPO=owner/repo     default BimxyzDev/vpsnat
#   VPSNAT_BRANCH=branch       default main
#   VPSNAT_REF=<sha>           kunci ke satu commit
#   VPSNAT_SKIP_TESTS=1        lewati tes sebelum pemasangan
#
# Bisa dijalankan dari clone lokal (bash scripts/install-node.sh) maupun lewat
# curl | bash: bootstrap diunduh dari repo yang sama bila belum ada di disk.

set -uo pipefail

vpsnat_launch() {
  local role="node" here src repo branch tmp
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")
  src="${here}/_bootstrap.sh"
  if [[ ! -s "$src" ]]; then
    repo="${VPSNAT_REPO:-BimxyzDev/vpsnat}"; branch="${VPSNAT_BRANCH:-main}"
    tmp=$(mktemp -d) || { echo "[x] Tidak bisa membuat direktori sementara." >&2; return 1; }
    echo "[i] Mengunduh bootstrap dari ${repo}@${branch}..."
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 \
      "https://raw.githubusercontent.com/${repo}/${branch}/scripts/_bootstrap.sh" -o "$tmp/_bootstrap.sh" \
      || { echo "[x] Gagal mengunduh scripts/_bootstrap.sh." >&2; rm -rf "$tmp"; return 1; }
    src="$tmp/_bootstrap.sh"
    bash "$src" "$role" "$@"; local rc=$?
    rm -rf "$tmp"
    return $rc
  fi
  bash "$src" "$role" "$@"
}

vpsnat_launch "$@"; exit $?
