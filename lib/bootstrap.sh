#!/usr/bin/env bash
# VPSNAT bootstrap: memuat seluruh modul sesuai peran instalasi.
#
# Struktur sumber (root repo = $VPSNAT_APP_DIR):
#   bin/vpsnat          entry point CLI
#   lib/core/*.sh       inti: config, log, DB node, audit, settings
#   lib/node/*.sh       operasi data-plane (LXD, NAT, bandwidth, expiry, relay)
#   lib/panel/*.sh      operasi control-plane (registry node, alokasi)
#   lib/system/*.sh     install/update/service web & bot
#   lib/cli/cli.sh      router perintah + menu
#   panel/              aplikasi panel (Python): app.py, bot.py, db.py, web/
#   node/               daemon node (Python): agent.py
#
# Peran (VPSNAT_ROLE / /etc/vpsnat/role):
#   panel  hanya control-plane; tidak menjalankan LXD/tidak ada VPS client
#   node   hanya data-plane (LXD + NAT + agent); melayani perintah panel
#   both   satu host menjalankan keduanya (mode lama, tetap didukung)

set -uo pipefail

VPSNAT_APP_DIR="${VPSNAT_APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export VPSNAT_APP_DIR

VPSNAT_LIB_DIR="${VPSNAT_LIB_DIR:-${VPSNAT_APP_DIR}/lib}"
VPSNAT_PANEL_DIR="${VPSNAT_PANEL_DIR:-${VPSNAT_APP_DIR}/panel}"
VPSNAT_NODE_DIR="${VPSNAT_NODE_DIR:-${VPSNAT_APP_DIR}/node}"

# Sub-path di dalam paket runtime (dipakai installer).
VPSNAT_LIB_CORE="${VPSNAT_LIB_DIR}/core"
VPSNAT_LIB_NODE="${VPSNAT_LIB_DIR}/node"
VPSNAT_LIB_PANEL="${VPSNAT_LIB_DIR}/panel"
VPSNAT_LIB_SYSTEM="${VPSNAT_LIB_DIR}/system"
VPSNAT_LIB_CLI="${VPSNAT_LIB_DIR}/cli"

# shellcheck source=/dev/null
source "${VPSNAT_LIB_CORE}/core.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_CORE}/db.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_CORE}/audit.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_CORE}/settings.sh"

# Data-plane (aman dimuat di panel: hanya definisi fungsi, tidak menyentuh LXD saat source).
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/network.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/harden.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/ports.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/bandwidth.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/vps.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/expire.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/resource.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/data.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/nodes.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_NODE}/relay.sh"

# Control-plane (registry node + alokasi port pada panel).
# shellcheck source=/dev/null
source "${VPSNAT_LIB_PANEL}/registry.sh"

# Layanan: installer, updater, panel & node, web panel, bot Telegram.
# shellcheck source=/dev/null
source "${VPSNAT_LIB_SYSTEM}/install.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_SYSTEM}/panel.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_SYSTEM}/node.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_SYSTEM}/update.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_SYSTEM}/web.sh"
# shellcheck source=/dev/null
source "${VPSNAT_LIB_SYSTEM}/bot.sh"

# Router perintah (dimuat terakhir: butuh seluruh fungsi di atas).
# shellcheck source=/dev/null
source "${VPSNAT_LIB_CLI}/cli.sh"

vpsnat_bootstrap_done=1
