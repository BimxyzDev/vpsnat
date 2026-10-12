#!/usr/bin/env bash

parse_duration() {
  local in="${1:-}" now num unit seconds epoch
  now=$(date +%s)
  case "${in,,}" in ""|0|never|none|-) echo 0; return 0;; esac
  if [[ "$in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    epoch=$(date -d "$in 23:59:59" +%s 2>/dev/null) || return 1
    [[ "$(date -d "@$epoch" +%F 2>/dev/null)" == "$in" ]] || return 1
    [[ "$epoch" =~ ^[0-9]{1,12}$ ]] || return 1
    # Reject pre-epoch dates and values outside the supported 10-year window.
    (( epoch > 0 && epoch <= now + 315576000 )) || return 1
    echo "$epoch"; return 0
  fi
  if [[ "$in" =~ ^([0-9]+)([hdwm])$ ]]; then
    num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
    # Bound digits before arithmetic; this prevents shell integer overflow from hostile input.
    (( ${#num} <= 7 )) || return 1
    num=$((10#$num))
    case "$unit" in
      h) (( num >= 1 && num <= 87600 )) || return 1; seconds=$((num*3600));;
      d) (( num >= 1 && num <= 3652 )) || return 1; seconds=$((num*86400));;
      w) (( num >= 1 && num <= 521 )) || return 1; seconds=$((num*7*86400));;
      m) (( num >= 1 && num <= 120 )) || return 1; seconds=$((num*30*86400));;
    esac
    echo $((now+seconds)); return 0
  fi
  return 1
}

fmt_epoch() {
  local e="${1:-0}"
  [[ -z "$e" || "$e" == "0" ]] && { echo "tanpa expired"; return; }
  [[ "$e" =~ ^[0-9]{1,12}$ ]] || { echo "expired invalid"; return 0; }
  e=$((10#$e))
  (( e <= $(date +%s) + 315576000 )) || { echo "expired invalid"; return 0; }
  date -d "@$e" '+%F %H:%M' 2>/dev/null || echo "expired invalid"
}

remain_str() {
  local e="${1:-0}" now diff d h
  [[ -z "$e" || "$e" == "0" ]] && { echo "-"; return; }
  [[ "$e" =~ ^[0-9]{1,12}$ ]] || { echo "invalid"; return 0; }
  e=$((10#$e))
  now=$(date +%s)
  (( e <= now + 315576000 )) || { echo "invalid"; return 0; }
  diff=$((e-now))
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

__vps_suspend_auto_locked() {
  local n="$1" reason="${2:-manual}"
  db_set_fields "$n" "13=1" "25=$reason" "20=0" || { err "Gagal menyimpan status suspension ${n}; guest tidak dianggap tersuspend."; return 1; }
  local stop_failed=0 boot_failed=0
  if ! lxc stop "$n" --timeout 20 2>/dev/null && ! lxc stop "$n" --force 2>/dev/null; then
    stop_failed=1
    warn "Guest ${n} tidak berhasil dihentikan; forwarding tetap ditarik jika firewall tersedia."
  fi
  lxc config set "$n" boot.autostart false 2>/dev/null || { boot_failed=1; err "Gagal menonaktifkan boot.autostart untuk ${n}."; }
  apply_all_rules || { err "${n} ditandai suspended di DB, tetapi firewall gagal diperbarui. Periksa forwarding segera."; return 1; }
  log "SUSPEND ${n} reason=${reason}"
  if (( stop_failed || boot_failed )); then
    err "Suspension ${n} tercatat dan forwarding ditarik, tetapi perlu rekonsiliasi guest/autostart manual."
    return 1
  fi
}

_vps_suspend_auto() { with_alloc_lock __vps_suspend_auto_locked "$@"; }


_vps_suspend() { _vps_suspend_auto "$1" "expired"; }

__vps_unsuspend_locked() {
  local n="$1" reason exp now
  reason=$(db_field "$n" 25); reason=${reason:--}
  exp=$(db_field "$n" 11); exp=${exp:-0}; now=$(date +%s)
  if [[ "$exp" != "0" ]] && (( exp <= now )); then
    err "${n} masih expired. Renew/set-expire dulu."
    return 1
  fi
  lxc config set "$n" boot.autostart true 2>/dev/null || { err "Gagal mengaktifkan boot.autostart untuk ${n}; suspension dipertahankan."; return 1; }
  db_set_fields "$n" "13=0" "25=-" "20=0" "21=0" "22=$now" || {
    lxc config set "$n" boot.autostart false 2>/dev/null || true
    err "Gagal menyimpan unsuspend ${n}; DB tetap authoritative."; return 1;
  }
  if ! apply_all_rules; then
    db_set_fields "$n" "13=1" "25=$reason" || err "GAGAL rollback status ${n} setelah firewall gagal."
    lxc config set "$n" boot.autostart false 2>/dev/null || true
    apply_all_rules || err "Firewall gagal juga setelah rollback; periksa rule aktif segera."
    err "Unsuspend ${n} dibatalkan karena firewall gagal."; return 1
  fi
  if ! lxc start "$n"; then
    db_set_fields "$n" "13=1" "25=$reason" || err "GAGAL rollback status ${n} setelah start gagal."
    lxc config set "$n" boot.autostart false 2>/dev/null || true
    apply_all_rules || err "Firewall gagal juga setelah rollback unsuspend."
    err "${n} tidak berhasil start; status suspension dipulihkan."; return 1
  fi
  ok "${n} diaktifkan kembali."
  log "UNSUSPEND ${n}"
}

_vps_unsuspend() { with_alloc_lock __vps_unsuspend_locked "$@"; }


_vps_setexpire_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local dur="${2:-${EXPIRE:-}}" e
  [[ -z "$dur" ]] && ask dur "Masa aktif dari sekarang (30d, 2w, 1m, 2026-12-31, never): "
  e=$(parse_duration "$dur") || { err "Format expired invalid."; return 1; }
  db_set_field "$n" 11 "$e" || { err "Gagal menyimpan expiry ${n}; konfigurasi lama dipertahankan."; return 1; }
  if [[ "$(db_field "$n" 13)" == "1" && "$(db_field "$n" 25)" == "expired" && ( "$e" == "0" || "$e" -gt "$(date +%s)" ) ]]; then
    _vps_unsuspend "$n" || { err "Expiry tersimpan, tetapi ${n} masih suspended karena activation gagal."; return 1; }
  fi
  ok "Expired ${n}: $(fmt_epoch "$e")"
}

vps_setexpire() { with_alloc_lock _vps_setexpire_locked "$@"; }


_vps_renew_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local dur="${2:-${EXPIRE:-}}" cur now base add e reason duration_epoch
  [[ -z "$dur" ]] && ask dur "Perpanjang berapa lama (30d, 2w, 1m): "
  [[ "$dur" =~ ^[0-9]+[hdwm]$ ]] || { err "Renew hanya menerima durasi relatif."; return 1; }
  now=$(date +%s); duration_epoch=$(parse_duration "$dur") || { err "Durasi renew di luar batas atau invalid."; return 1; }
  cur=$(db_field "$n" 11); cur=${cur:-0}; base=$cur
  [[ "$cur" =~ ^[0-9]{1,12}$ ]] || { err "Timestamp expired di database tidak valid."; return 1; }
  cur=$((10#$cur)); base=$cur
  (( cur == 0 || cur <= now + 315576000 )) || { err "Timestamp expired di database di luar rentang yang diizinkan; periksa DB manual."; return 1; }
  { (( cur == 0 )) || ((cur<now)); } && base=$now
  add=$((duration_epoch-now)); e=$((base+add))
  (( e > 0 && e <= now + 315576000 )) || { err "Timestamp renew hasil perhitungan di luar batas yang diizinkan."; return 1; }
  db_set_field "$n" 11 "$e" || { err "Gagal menyimpan renewal ${n}; expiry lama dipertahankan."; return 1; }
  # Renewal membuka kuota periode baru dan menghapus suspension karena quota/resource.
  bandwidth_reset "$n" >/dev/null 2>&1 || true
  reason=$(db_field "$n" 25); reason=${reason:--}
  if [[ "$(db_field "$n" 13)" == "1" && "$reason" == "expired" ]]; then
    _vps_unsuspend "$n" || { err "Renew tersimpan, tetapi ${n} tetap suspended karena activation gagal."; return 1; }
  fi
  ok "${n} diperpanjang ${dur}. Expired baru: $(fmt_epoch "$e")"
}

vps_renew() { with_alloc_lock _vps_renew_locked "$@"; }


_vps_suspend_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  _vps_suspend_auto "$n" "manual" || return 1
  ok "${n} disuspend."
}

vps_suspend() { with_alloc_lock _vps_suspend_locked "$@"; }


_vps_unsuspend_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  _vps_unsuspend "$n"
}

vps_unsuspend() { with_alloc_lock _vps_unsuspend_locked "$@"; }


_vps_setowner_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local o="${2:-${OWNER:-}}"
  [[ -z "$o" ]] && ask o "Owner (label / chat_id Telegram): "
  [[ "${#o}" -le 60 && "$o" != *"|"* && "$o" != *$'\n'* && "$o" != *$'\r'* ]] || { err "Owner maksimal 60 karakter tanpa pipe/newline."; return 1; }
  db_set_field "$n" 12 "${o:--}" || { err "Gagal menyimpan owner ${n}."; return 1; }
  ok "Owner ${n}: ${o:--}"
}

vps_setowner() { with_alloc_lock _vps_setowner_locked "$@"; }


_vps_expire_check_locked() {
  need_root
  local grace now name exp susp hrs marker msg
  db_init || { err "Gagal membaca/migrasi DB; expiry-check dibatalkan."; return 1; }
  grace=$(cfg_int GRACE_DAYS "$GRACE_DAYS_DEFAULT")
  if [[ ! "$grace" =~ ^[0-9]{1,4}$ ]] || (( 10#$grace < 1 || 10#$grace > 3650 )); then
    warn "GRACE_DAYS invalid; memakai default ${GRACE_DAYS_DEFAULT}."
    grace=$GRACE_DAYS_DEFAULT
  else
    grace=$((10#$grace))
  fi
  now=$(date +%s); mkdir -p "$NOTIF_DIR"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    exp=$(db_field "$name" 11); exp=${exp:-0}; susp=$(db_field "$name" 13); susp=${susp:-0}
    [[ "$exp" != "0" ]] || continue
    if [[ ! "$exp" =~ ^[0-9]{1,12}$ ]]; then
      warn "Expiry timestamp ${name} tidak valid; purge ditahan dan record dipertahankan."
      continue
    fi
    exp=$((10#$exp))
    if (( exp > now + 315576000 )); then
      warn "Expiry timestamp ${name} di luar rentang 10 tahun; purge ditahan untuk pemeriksaan manual."
      continue
    fi
    if (( exp <= now )); then
      # Keep an existing manual/resource suspension reason, but expiry/grace still applies.
      if [[ "$susp" != "1" ]]; then
        _vps_suspend_auto "$name" "expired" || { warn "Expiry suspension ${name} gagal; akan dicoba lagi pada siklus berikutnya."; continue; }
        susp=1
      fi
      if [[ ! -e "$NOTIF_DIR/${name}.expired" ]]; then
        touch "$NOTIF_DIR/${name}.expired"
        msg="⏸ VPS ${name} EXPIRED. VPS ditahan selama ${grace} hari dan dihapus permanen jika tidak diperpanjang."; info "$msg"; tg_notify "$msg"
      fi
      if (( now-exp >= grace*86400 )); then
        msg="🗑 VPS ${name} melewati masa tenggang ${grace} hari → DIHAPUS permanen."; info "$msg"; tg_notify "$msg"
        if _vps_purge "$name"; then
          rm -f "$NOTIF_DIR/${name}."* 2>/dev/null || true
        else
          warn "Purge ${name} gagal; record/port dipertahankan dan akan dicoba ulang."
        fi
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

vps_expire_check() { with_alloc_lock _vps_expire_check_locked "$@"; }


vps_expiring() {
  local within="${1:-7}" now name exp found=0
  [[ "$within" =~ ^[0-9]{1,4}$ ]] && (( 10#$within <= 3650 )) || { err "Hari harus integer 0-3650."; return 1; }
  within=$((10#$within))
  now=$(date +%s); printf "${W}%-16s %-18s %-12s${N}\n" NAME EXPIRED SISA; echo "------------------------------------------------"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    exp=$(db_field "$name" 11); exp=${exp:-0}
    [[ "$exp" != "0" ]] || continue
    [[ "$exp" =~ ^[0-9]{1,12}$ ]] || { warn "Expiry timestamp ${name} tidak valid; dilewati."; continue; }
    exp=$((10#$exp))
    if (( exp > now + 315576000 )); then warn "Expiry timestamp ${name} di luar rentang; dilewati."; continue; fi
    if ((exp-now<=within*86400)); then printf "%-16s %-18s %-12s\n" "$name" "$(fmt_epoch "$exp")" "$(remain_str "$exp")"; found=1; fi
  done < <(cut -d'|' -f1 "$DB_FILE")
  ((found)) || echo "(tidak ada yang expired dalam ${within} hari)"
}
