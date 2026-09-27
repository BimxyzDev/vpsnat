#!/usr/bin/env bash
set -u
BASE_DIR=${VPSNAT_BASE_DIR:-/etc/vpsnat}
BIN=${VPSNAT_BIN:-/usr/local/bin/vpsnat}
[[ -x "$BIN" ]] || { echo "vpsnat belum terinstall: $BIN"; exit 1; }
echo "== service =="
systemctl is-active vpsnat-monitor.service 2>/dev/null || true
systemctl is-active vpsnat-expire.timer 2>/dev/null || true
echo "== CLI check =="
"$BIN" check
echo "== DB =="
[[ -f "$BASE_DIR/vps.db" ]] && wc -l "$BASE_DIR/vps.db" || echo "DB belum ada"
