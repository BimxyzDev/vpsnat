#!/usr/bin/env bash

parse_duration() {
  local in="${1:-}" now num unit
  now=$(date +%s)
  case "${in,,}" in ""|0|never|none|-) echo 0; return 0;; esac
  if [[ "$in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then date -d "$in 23:59:59" +%s 2>/dev/null || return 1; return 0; fi
  if [[ "$in" =~ ^([0-9]+)([hdwm])$ ]]; then
    num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
    case "$unit" in h) echo $((now+num*3600));; d) echo $((now+num*86400));; w) echo $((now+num*7*86400));; m) echo $((now+num*30*86400));; esac
    return 0
  fi
  return 1
}

fmt_epoch() {
  local e="${1:-0}"
  [[ -z "$e" || "$e" == "0" ]] && { echo "tanpa expired"; return; }
  date -d "@$e" '+%F %H:%M'
}

remain_str() {
  local e="${1:-0}" now diff d h
  [[ -z "$e" || "$e" == "0" ]] && { echo "-"; return; }
  now=$(date +%s); diff=$((e-now))
  if (( diff <= 0 )); then d=$(((-diff)/86400)); echo "lewat ${d}h"; else d=$((diff/86400)); h=$(((diff%86400)/3600)); echo "${d}h ${h}j"; fi
}

tg_notify() {
  local token chat text="$1" c
  token=$(conf_get TG_TOKEN); chat=$(conf_get TG_ADMIN)
  [[ -z "$token" || -z "$chat" ]] && return 0
  for c in ${chat//,/ }; do
    curl -s -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" --data-urlencode "chat_id=${c}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true
  done
}

_vps_suspend_auto() {
  local n="$1" reason="${2:-manual}"
  db_set_fields "$n" "13=1" "25=$reason" "20=0"
  lxc stop "$n" --timeout 20 2>/dev/null || lxc stop "$n" --force 2>/dev/null || true
  lxc config set "$n" boot.autostart false 2>/dev/null || true
  apply_all_rules
  log "SUSPEND ${n} reason=${reason}"
}

_vps_suspend() { _vps_suspend_auto "$1" "expired"; }

_vps_unsuspend() {
  local n="$1" reason exp now
  reason=$(db_field "$n" 25); reason=${reason:--}
  exp=$(db_field "$n" 11); exp=${exp:-0}; now=$(date +%s)
  if [[ "$reason" == "expired" && "$exp" != "0" && "$exp" -le "$now" ]]; then
    err "${n} masih expired. Renew/set-expire dulu."
    return 1
  fi
  db_set_fields "$n" "13=0" "25=-" "20=0" "21=0" "22=$now"
  lxc config set "$n" boot.autostart true 2>/dev/null || true
  apply_all_rules
  lxc start "$n" 2>/dev/null || true
  ok "${n} diaktifkan kembali."
  log "UNSUSPEND ${n}"
}

vps_setexpire() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local dur="${2:-${EXPIRE:-}}" e
  [[ -z "$dur" ]] && ask dur "Masa aktif dari sekarang (30d, 2w, 1m, 2026-12-31, never): "
  e=$(parse_duration "$dur") || { err "Format expired invalid."; return 1; }
  db_set_field "$n" 11 "$e"
  if [[ "$(db_field "$n" 13)" == "1" && "$(db_field "$n" 25)" == "expired" && ( "$e" == "0" || "$e" -gt "$(date +%s)" ) ]]; then _vps_unsuspend "$n" || true; fi
  ok "Expired ${n}: $(fmt_epoch "$e")"
}

vps_renew() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local dur="${2:-${EXPIRE:-}}" cur now base add e
  [[ -z "$dur" ]] && ask dur "Perpanjang berapa lama (30d, 2w, 1m): "
  [[ "$dur" =~ ^[0-9]+[hdwm]$ ]] || { err "Renew hanya menerima durasi relatif."; return 1; }
  now=$(date +%s); cur=$(db_field "$n" 11); cur=${cur:-0}; base=$cur
  { [[ "$cur" == "0" ]] || ((cur<now)); } && base=$now
  add=$(( $(parse_duration "$dur") - now )); e=$((base+add))
  db_set_field "$n" 11 "$e"
  # Renewal membuka kuota periode baru dan menghapus suspension karena quota/resource.
  bandwidth_reset "$n" >/dev/null 2>&1 || true
  if [[ "$(db_field "$n" 13)" == "1" ]]; then _vps_unsuspend "$n" || true; fi
  ok "${n} diperpanjang ${dur}. Expired baru: $(fmt_epoch "$e")"
}

vps_suspend() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  _vps_suspend_auto "$n" "manual"
  ok "${n} disuspend."
}

vps_unsuspend() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  _vps_unsuspend "$n"
}

vps_setowner() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local o="${2:-${OWNER:-}}"
  [[ -z "$o" ]] && ask o "Owner (label / chat_id Telegram): "
  [[ "$o" == *"|"* ]] && { err "Owner tidak boleh mengandung |"; return 1; }
  db_set_field "$n" 12 "${o:--}"
  ok "Owner ${n}: ${o:--}"
}

vps_expire_check() {
  need_root
  local grace now name exp susp hrs marker msg
  db_init; grace=$(cfg_int GRACE_DAYS "$GRACE_DAYS_DEFAULT"); now=$(date +%s); mkdir -p "$NOTIF_DIR"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    exp=$(db_field "$name" 11); exp=${exp:-0}; susp=$(db_field "$name" 13); susp=${susp:-0}
    [[ "$exp" != "0" ]] || continue
    if (( exp <= now )); then
      if [[ "$susp" != "1" ]]; then
        _vps_suspend_auto "$name" "expired"
        msg="⏸ VPS ${name} EXPIRED & disuspend. Otomatis dihapus dalam ${grace} hari jika tidak diperpanjang."; info "$msg"; tg_notify "$msg"
      elif (( now-exp >= grace*86400 )) && [[ "$(db_field "$name" 25)" == "expired" ]]; then
        msg="🗑 VPS ${name} melewati masa tenggang ${grace} hari → DIHAPUS permanen."; info "$msg"; tg_notify "$msg"; _vps_purge "$name"; rm -f "$NOTIF_DIR/${name}."* 2>/dev/null || true
      fi
      continue
    fi
    hrs=$(((exp-now)/3600))
    for marker in 72 24; do
      if ((hrs<=marker)) && [[ ! -e "$NOTIF_DIR/${name}.${marker}" ]]; then
        touch "$NOTIF_DIR/${name}.${marker}"; msg="⚠️ VPS ${name} akan expired ≤${marker} jam lagi ($(fmt_epoch "$exp")). Renew: vpsnat renew ${name} 30d"; info "$msg"; tg_notify "$msg"
      fi
    done
    ((hrs>72)) && rm -f "$NOTIF_DIR/${name}."* 2>/dev/null || true
  done < <(cut -d'|' -f1 "$DB_FILE")
}

vps_expiring() {
  local within="${1:-7}" now name exp found=0
  [[ "$within" =~ ^[0-9]+$ ]] || { err "Hari harus angka."; return 1; }
  now=$(date +%s); printf "${W}%-16s %-18s %-12s${N}\n" NAME EXPIRED SISA; echo "------------------------------------------------"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    exp=$(db_field "$name" 11); exp=${exp:-0}
    [[ "$exp" != "0" ]] || continue
    if ((exp-now<=within*86400)); then printf "%-16s %-18s %-12s\n" "$name" "$(fmt_epoch "$exp")" "$(remain_str "$exp")"; found=1; fi
  done < <(cut -d'|' -f1 "$DB_FILE")
  ((found)) || echo "(tidak ada yang expired dalam ${within} hari)"
}
