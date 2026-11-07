#!/usr/bin/env bash
# Bootstrap bersama untuk scripts/install-panel.sh dan scripts/install-node.sh.
#
# Mengunduh source pada commit terbaru, menjalankan tes, lalu memanggil
# `bin/vpsnat install-panel` atau `install-node`. Seluruh isi dibungkus fungsi dan
# dipanggil di baris terakhir, jadi unduhan yang terpotong tidak menjalankan
# perintah setengah jadi.
#
#   bash _bootstrap.sh panel|node [--check] [--force]

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: _bootstrap.sh <panel|node> [--check] [--force]

  panel   pasang control-plane (DB client, web panel, bot, worker)
  node    pasang data-plane (LXD, NAT, agent)
  --check hanya tampilkan versi/commit, tanpa mengubah apa pun
  --force pasang ulang commit terbaru walau sudah terpasang

Environment: VPSNAT_REPO, VPSNAT_BRANCH, VPSNAT_REF, VPSNAT_SKIP_TESTS
EOF
}

vpsnat_bootstrap() (
  local role="${1:-}"; shift || true
  local mode="apply" force=0 repo branch commit work src
  local bin lib marker installed_commit="" installed_version="" new_version="" installed=0

  case "$role" in
    panel|node) ;;
    -h|--help) usage; return 0 ;;
    *) echo "[x] Peran harus panel atau node." >&2; usage >&2; return 2 ;;
  esac

  while (($#)); do
    case "$1" in
      --check) mode="check" ;;
      --force) force=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "[x] Argumen tidak dikenal: $1" >&2; return 2 ;;
    esac
    shift
  done

  repo="${VPSNAT_REPO:-BimxyzDev/vpsnat}"
  branch="${VPSNAT_BRANCH:-main}"
  bin="${VPSNAT_BIN:-/usr/local/bin/vpsnat}"
  lib="${VPSNAT_LIB:-/usr/local/lib/vpsnat}"
  marker="${VPSNAT_COMMIT_FILE:-/etc/vpsnat/source.commit}"

  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "[x] VPSNAT_REPO harus berbentuk owner/repo." >&2; return 2; }
  [[ "$branch" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "[x] Nama branch tidak valid." >&2; return 2; }
  if [[ "$mode" != "check" && "$EUID" -ne 0 ]]; then
    echo "[x] Jalankan sebagai root: curl -fsSL <url> | sudo bash" >&2
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "[x] curl belum terpasang (apt-get install -y curl)." >&2; return 1; }
  command -v tar >/dev/null 2>&1 || { echo "[x] tar belum terpasang." >&2; return 1; }

  work=$(mktemp -d) || { echo "[x] Tidak bisa membuat direktori sementara." >&2; return 1; }
  trap 'rm -rf "$work"' EXIT

  if [[ -n "${VPSNAT_REF:-}" ]]; then
    commit="$VPSNAT_REF"
  else
    if ! commit=$(curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 \
        -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${repo}/commits/${branch}"); then
      echo "[x] Gagal mengambil commit terbaru dari GitHub (cek koneksi atau rate limit API)." >&2
      return 1
    fi
  fi
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "[x] SHA commit tidak valid." >&2; return 1; }

  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 \
      "https://raw.githubusercontent.com/${repo}/${commit}/lib/core/core.sh" -o "$work/core.sh"; then
    echo "[x] Gagal membaca versi dari repo." >&2
    return 1
  fi
  new_version=$(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$work/core.sh" | head -n1)
  [[ -n "$new_version" ]] || { echo "[x] VERSION tidak ditemukan di lib/core/core.sh repo." >&2; return 1; }

  if [[ -x "$bin" && -d "$lib" ]]; then
    installed=1
    [[ -r "$lib/lib/core/core.sh" ]] && installed_version=$(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$lib/lib/core/core.sh" | head -n1)
    [[ -z "$installed_version" && -r "$lib/core.sh" ]] && installed_version=$(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$lib/core.sh" | head -n1)
    [[ -r "$marker" ]] && { IFS= read -r installed_commit < "$marker" || true; }
  fi

  printf 'Peran            : %s\nVPSNAT terpasang : %s\nVersi repo       : %s\nCommit repo      : %s\n' \
    "$role" "$([[ $installed -eq 1 ]] && echo "${installed_version:-tidak diketahui}" || echo 'belum terpasang')" \
    "$new_version" "$commit"

  if [[ "$mode" == "check" ]]; then
    if [[ $installed -eq 0 ]]; then
      echo "[i] Belum terpasang. Jalankan tanpa --check untuk install."
    elif [[ "$installed_commit" == "$commit" ]]; then
      echo "[+] Sudah di commit terbaru."
    else
      echo "[i] Update tersedia. Jalankan tanpa --check untuk update."
    fi
    return 0
  fi
  if [[ $force -ne 1 && $installed -eq 1 && "$installed_commit" == "$commit" ]]; then
    echo "[+] VPSNAT sudah menggunakan source terbaru."
    return 0
  fi

  echo "[i] Mengunduh source..."
  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 300 --retry 2 \
      "https://codeload.github.com/${repo}/tar.gz/${commit}" -o "$work/source.tar.gz"; then
    echo "[x] Gagal mengunduh source archive." >&2
    return 1
  fi
  src="$work/source"
  mkdir -p "$src" || return 1
  tar -xzf "$work/source.tar.gz" --strip-components=1 --no-same-owner -C "$src" || { echo "[x] Source archive tidak bisa diekstrak." >&2; return 1; }
  for required in bin/vpsnat lib/bootstrap.sh lib/core/core.sh lib/cli/cli.sh lib/system/install.sh lib/system/panel.sh lib/system/node.sh; do
    [[ -s "$src/$required" ]] || { printf '[x] Source repo tidak lengkap: %s\n' "$required" >&2; return 1; }
  done
  if [[ "$role" == "panel" ]]; then
    for required in panel/app.py panel/panelapp.py panel/db.py panel/web/pages/dashboard.html; do
      [[ -s "$src/$required" ]] || { printf '[x] Paket panel tidak lengkap: %s\n' "$required" >&2; return 1; }
    done
  else
    [[ -s "$src/node/agent.py" ]] || { echo "[x] Paket node tidak lengkap: node/agent.py" >&2; return 1; }
  fi

  if [[ "${VPSNAT_SKIP_TESTS:-0}" != "1" ]]; then
    echo "[i] Menjalankan tes regresi sebelum pemasangan..."
    bash "$src/tests/test.sh" || { echo "[x] Tes gagal. Instalasi tidak diubah." >&2; return 1; }
  fi

  export VPSNAT_APP_DIR="$src"
  local sub="install-${role}"
  [[ $installed -eq 1 ]] && sub="upgrade"
  echo "[i] ${sub} VPSNAT ${new_version} (${role}) dari commit ${commit:0:12}..."
  if [[ -t 0 ]]; then
    bash "$src/bin/vpsnat" "$sub"
  elif { : </dev/tty; } 2>/dev/null; then
    bash "$src/bin/vpsnat" "$sub" </dev/tty
  else
    VPSNAT_NONINTERACTIVE=1 bash "$src/bin/vpsnat" "$sub" </dev/null
  fi || { echo "[x] Proses ${sub} gagal. Commit belum dicatat." >&2; return 1; }

  mkdir -p "$(dirname "$marker")" || return 1
  printf '%s\n' "$commit" > "${marker}.tmp.$$" || return 1
  chmod 600 "${marker}.tmp.$$" && mv -f "${marker}.tmp.$$" "$marker" || return 1
  echo "[+] Selesai: VPSNAT ${new_version} (${commit:0:12}), peran ${role}."
  if [[ "$role" == "panel" ]]; then
    echo "[i] Langkah berikutnya: vpsnat web-setup  lalu  vpsnat node add <nama> <url> <wan-ip>"
  else
    echo "[i] Langkah berikutnya: catat token dari  vpsnat node init  lalu daftarkan di panel."
  fi
)

vpsnat_bootstrap "$@"; exit $?
