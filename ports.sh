#!/usr/bin/env bash

ports_get() { db_field "$1" 7; }
ports_set() { db_set_field "$1" 7 "$2"; }
ports_add_entry() {
  local name="$1" entry="$2" cur
  cur=$(ports_get "$name")
  if [[ -z "$cur" || "$cur" == "-" ]]; then ports_set "$name" "$entry"; else ports_set "$name" "${cur},${entry}"; fi
}
ports_remove_entry() {
  local name="$1" entry="$2" cur new
  cur=$(ports_get "$name"); new=$(echo "$cur" | tr ',' '\n' | grep -vxF "$entry" | paste -sd, -); [[ -z "$new" ]] && new="-"; ports_set "$name" "$new"
}

_port_add_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local proto count int_start range start end p i ip added=0
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    proto="${PROTO:-tcp}"; count="${COUNT:-${NPORTS_ADD:-}}"; int_start="${INT_START:-}"
  else
    read -rp "Protokol (tcp/udp/both) [tcp]: " proto; proto=${proto:-tcp}
    read -rp "Jumlah port yang ditambahkan: " count
  fi
  [[ "$proto" =~ ^(tcp|udp|both)$ ]] || { err "Protokol invalid."; return 1; }
  [[ "$count" =~ ^[0-9]{1,3}$ ]] || { err "Jumlah port harus integer 1-500."; return 1; }
  count=$((10#$count))
  (( count >= 1 && count <= 500 )) || { err "Jumlah port harus 1-500."; return 1; }
  local ports_out explicit_int=0
  local -a plist
  [[ -n "${int_start:-}" ]] && explicit_int=1
  ports_out=$(alloc_ports "$count") || {
    err "Tidak ditemukan ${count} port kosong (maksimal $(cfg_int PORT_SPLIT_MAX_CHUNKS "$PORT_SPLIT_MAX_CHUNKS_DEFAULT") blok kontigu)."
    return 1
  }
  mapfile -t plist <<< "$ports_out"
  (( ${#plist[@]} == count )) || { err "Alokasi port tidak lengkap (${#plist[@]}/${count})."; return 1; }
  ip=$(db_field "$n" 2)
  if (( explicit_int )); then
    [[ "$int_start" =~ ^[0-9]{1,5}$ ]] || { err "INT_START invalid."; return 1; }
    int_start=$((10#$int_start))
    (( int_start >= 1 && int_start + count - 1 <= 65535 )) || { err "INT_START harus berada pada rentang 1-65535."; return 1; }
  fi

  local original newports entry
  original=$(ports_get "$n"); newports="$original"
  for i in "${!plist[@]}"; do
    p=${plist[$i]}
    local int=$p
    (( explicit_int )) && int=$((int_start+i))
    if [[ "$proto" == "both" ]]; then
      entry="tcp:${p}:${int}"; [[ "$newports" == "-" || -z "$newports" ]] && newports="$entry" || newports+=",$entry"
      entry="udp:${p}:${int}"; newports+=",$entry"
    else
      entry="${proto}:${p}:${int}"; [[ "$newports" == "-" || -z "$newports" ]] && newports="$entry" || newports+=",$entry"
    fi
    ((added+=1))
  done
  ports_set "$n" "$newports" || { err "Gagal menyimpan mapping port; tidak ada perubahan firewall dilakukan."; return 1; }
  if ! apply_all_rules; then
    ports_set "$n" "${original:--}" || err "Rollback database port gagal; periksa DB secara manual."
    apply_all_rules || err "Firewall masih gagal setelah rollback; jalankan vpsnat restore setelah memperbaiki firewall."
    err "Penambahan port dibatalkan karena firewall gagal diterapkan."
    return 1
  fi
  audit_log "$(audit_actor_cli)" "port.add" "$n" "ok" "proto=${proto} count=${added} ports=$(port_ranges_label "${plist[@]}")"
  ok "${added} port ditambahkan: $(port_ranges_label "${plist[@]}") → ${n}"
}

port_add() { with_alloc_lock _port_add_locked "$@"; }

port_range_add() { port_add "$@"; }

_port_del_locked() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local ports ext e proto rest ex int ip ssh found=0 original newports
  ip=$(db_field "$n" 2); ssh=$(db_field "$n" 3); ports=$(ports_get "$n"); original="$ports"; newports=""
  if [[ "$NONINTERACTIVE" == "1" ]]; then ext="${EXT:-}"; else echo "Port aktif: ${ports//,/  }"; read -rp "Port publik yang dihapus: " ext; fi
  [[ "$ext" == "$ssh" ]] && { err "Port SSH tidak boleh dihapus."; return 1; }
  [[ "$ext" =~ ^[0-9]{1,5}$ ]] || { err "Port invalid."; return 1; }
  ext=$((10#$ext))
  (( ext >= 1 && ext <= 65535 )) || { err "Port harus 1-65535."; return 1; }
  for e in ${ports//,/ }; do
    proto=${e%%:*}; rest=${e#*:}; ex=${rest%%:*}
    if [[ "$ex" == "$ext" ]]; then found=1; continue; fi
    [[ -z "$newports" ]] && newports="$e" || newports+=",$e"
  done
  ((found)) || { err "Port tidak ditemukan."; return 1; }
  ports_set "$n" "${newports:--}" || { err "Gagal menyimpan perubahan port."; return 1; }
  if ! apply_all_rules; then
    ports_set "$n" "$original" || err "Rollback port gagal; database perlu diperiksa."
    apply_all_rules || err "Firewall tetap gagal setelah rollback."
    err "Penghapusan port dibatalkan karena firewall gagal diterapkan."
    return 1
  fi
  audit_log "$(audit_actor_cli)" "port.del" "$n" "ok" "public=${ext}"
  ok "Port ${ext} dihapus."
}

port_del() { with_alloc_lock _port_del_locked "$@"; }

port_list() {
  local n; n=$(pick_vps "${1:-}") || return 1
  local pubip ip; pubip=$(pub_ip); ip=$(db_field "$n" 2)
  echo -e "${W}Port forward ${n} (${ip})${N}"
  ports_get "$n" | tr ',' '\n' | awk -F: -v ip="$pubip" 'NF==3{k=$2":"$3; if(!(k in pr)){order[++n]=k; pr[k]=$1} else {pr[k]=pr[k]"+"$1}} END{for(i=1;i<=n;i++){split(order[i],a,":"); printf "  %-8s %s:%s -> %s\n", pr[order[i]], ip, a[1], a[2]}}'
}
