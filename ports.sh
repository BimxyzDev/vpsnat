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

port_add() {
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
  [[ "$count" =~ ^[0-9]+$ ]] && ((count>=1 && count<=500)) || { err "Jumlah port harus 1-500."; return 1; }
  range=$(alloc_contiguous_ports "$count") || { err "Tidak ditemukan range kontigu ${count} port yang kosong."; return 1; }
  read -r start end <<< "$range"
  ip=$(db_field "$n" 2)
  int_start=${int_start:-$start}
  [[ "$int_start" =~ ^[0-9]+$ ]] && ((int_start>=1 && int_start+count-1<=65535)) || { err "INT_START invalid."; return 1; }

  for p in $(seq "$start" "$end"); do
    i=$((p-start)); local int=$((int_start+i))
    if [[ "$(db_field "$n" 13)" != "1" && "$(db_field "$n" 19)" != "1" ]]; then fw_add_forward "$proto" "$p" "$ip" "$int"; fi
    if [[ "$proto" == "both" ]]; then ports_add_entry "$n" "tcp:${p}:${int}"; ports_add_entry "$n" "udp:${p}:${int}"; else ports_add_entry "$n" "${proto}:${p}:${int}"; fi
    ((added+=1))
  done
  fw_save
  ok "${added} port ditambahkan: ${start}-${end} → ${n}"
}

port_range_add() { port_add "$@"; }

port_del() {
  need_root
  local n; n=$(pick_vps "${1:-}") || return 1
  local ports ext e proto rest ex int ip ssh found=0
  ip=$(db_field "$n" 2); ssh=$(db_field "$n" 3); ports=$(ports_get "$n")
  if [[ "$NONINTERACTIVE" == "1" ]]; then ext="${EXT:-}"; else echo "Port aktif: ${ports//,/  }"; read -rp "Port publik yang dihapus: " ext; fi
  [[ "$ext" == "$ssh" ]] && { err "Port SSH tidak boleh dihapus."; return 1; }
  [[ "$ext" =~ ^[0-9]+$ ]] || { err "Port invalid."; return 1; }
  for e in ${ports//,/ }; do
    proto=${e%%:*}; rest=${e#*:}; ex=${rest%%:*}; int=${rest#*:}
    if [[ "$ex" == "$ext" ]]; then fw_del_forward "$proto" "$ex" "$ip" "$int"; ports_remove_entry "$n" "$e"; found=1; fi
  done
  ((found)) || { err "Port tidak ditemukan."; return 1; }
  fw_save; ok "Port ${ext} dihapus."
}

port_list() {
  local n; n=$(pick_vps "${1:-}") || return 1
  local pubip ip; pubip=$(pub_ip); ip=$(db_field "$n" 2)
  echo -e "${W}Port forward ${n} (${ip})${N}"
  ports_get "$n" | tr ',' '\n' | awk -F: -v ip="$pubip" 'NF==3{k=$2":"$3; if(!(k in pr)){order[++n]=k; pr[k]=$1} else {pr[k]=pr[k]"+"$1}} END{for(i=1;i<=n;i++){split(order[i],a,":"); printf "  %-8s %s:%s -> %s\n", pr[order[i]], ip, a[1], a[2]}}'
}
