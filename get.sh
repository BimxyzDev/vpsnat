#!/usr/bin/env bash
# VPSNAT bootstrap: install baru atau update ke versi terbaru dari GitHub dengan satu perintah.
#
#   curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/get.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/BimxyzDev/vpsnat/main/get.sh | sudo bash -s -- --check
#
# Seluruh isi script dibungkus fungsi dan baru dipanggil di baris terakhir, jadi unduhan yang
# terpotong tidak akan menjalankan perintah setengah jadi. Tidak perlu git clone.

set -uo pipefail

vpsnat_get_usage() {
  cat <<'EOF'
Usage: get.sh [--check] [--force]

  (tanpa opsi)  Install VPSNAT jika belum terpasang, atau update ke commit terbaru.
  --check       Hanya tampilkan versi/commit terpasang vs repo, tanpa mengubah apa pun.
  --force       Pasang ulang commit terbaru walau sudah terpasang.

Environment (opsional):
  VPSNAT_REPO=owner/repo   default BimxyzDev/vpsnat
  VPSNAT_BRANCH=branch     default main
  VPSNAT_REF=<sha 40 hex>  kunci ke satu commit tertentu (abaikan branch)
  VPSNAT_SKIP_TESTS=1      lewati test.sh sebelum memasang
EOF
}

vpsnat_get() (
  local mode="apply" force=0 repo branch commit work src
  local bin lib marker marker_tmp installed_commit="" installed_version="" new_version="" installed=0

  while (($#)); do
    case "$1" in
      --check) mode="check" ;;
      --force) force=1 ;;
      -h|--help) vpsnat_get_usage; return 0 ;;
      *) printf '[x] Argumen tidak dikenal: %s\n' "$1" >&2; vpsnat_get_usage >&2; return 2 ;;
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
    echo "[x] Jalankan sebagai root: curl -fsSL <url>/get.sh | sudo bash" >&2
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "[x] curl belum terpasang (apt-get install -y curl)." >&2; return 1; }
  command -v tar >/dev/null 2>&1 || { echo "[x] tar belum terpasang." >&2; return 1; }

  work=$(mktemp -d) || { echo "[x] Tidak bisa membuat direktori sementara." >&2; return 1; }
  trap 'rm -rf "$work"' EXIT

  if [[ -n "${VPSNAT_REF:-}" ]]; then
    commit="$VPSNAT_REF"
  else
    # Media type vnd.github.sha membalas SHA commit saja (teks polos), tanpa perlu python/jq.
    if ! commit=$(curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 \
        -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${repo}/commits/${branch}"); then
      echo "[x] Gagal mengambil commit terbaru dari GitHub (cek koneksi atau rate limit API)." >&2
      return 1
    fi
  fi
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "[x] SHA commit tidak valid." >&2; return 1; }

  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 \
      "https://raw.githubusercontent.com/${repo}/${commit}/core.sh" -o "$work/core.sh"; then
    echo "[x] Gagal membaca versi dari repo." >&2
    return 1
  fi
  new_version=$(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$work/core.sh" | head -n1)
  [[ -n "$new_version" ]] || { echo "[x] VERSION tidak ditemukan di core.sh repo." >&2; return 1; }

  if [[ -x "$bin" && -d "$lib" ]]; then
    installed=1
    [[ -r "$lib/core.sh" ]] && installed_version=$(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$lib/core.sh" | head -n1)
    [[ -r "$marker" ]] && { IFS= read -r installed_commit < "$marker" || true; }
  fi

  printf 'VPSNAT terpasang : %s\nVersi repo       : %s\nCommit repo      : %s\n' \
    "$([[ $installed -eq 1 ]] && echo "${installed_version:-tidak diketahui}" || echo 'belum terpasang')" "$new_version" "$commit"

  if [[ "$mode" == "check" ]]; then
    if [[ $installed -eq 0 ]]; then
      echo "[i] Belum terpasang. Jalankan tanpa --check untuk install."
    elif [[ "$installed_commit" == "$commit" ]]; then
      echo "[+] Sudah di commit terbaru."
    else
      echo "[i] Update tersedia atau commit lokal belum tercatat. Jalankan tanpa --check untuk update."
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
  for required in vpsnat core.sh cli.sh install.sh update.sh test.sh; do
    [[ -s "$src/$required" ]] || { printf '[x] Source repo tidak lengkap: %s\n' "$required" >&2; return 1; }
  done

  if [[ "${VPSNAT_SKIP_TESTS:-0}" != "1" ]]; then
    echo "[i] Menjalankan tes regresi sebelum pemasangan..."
    bash "$src/test.sh" || { echo "[x] Tes gagal. Instalasi tidak diubah." >&2; return 1; }
  fi

  export VPSNAT_APP_DIR="$src"
  # Saat dipipe (curl | bash) stdin adalah script itu sendiri; pakai terminal untuk prompt installer.
  # Tanpa terminal sama sekali, installer dijalankan non-interaktif dengan nilai default.
  local sub="install"
  [[ $installed -eq 1 ]] && sub="upgrade"
  echo "[i] ${sub^} VPSNAT ${new_version} dari commit ${commit:0:12}..."
  if [[ -t 0 ]]; then
    bash "$src/vpsnat" "$sub"
  elif { : </dev/tty; } 2>/dev/null; then
    bash "$src/vpsnat" "$sub" </dev/tty
  else
    VPSNAT_NONINTERACTIVE=1 bash "$src/vpsnat" "$sub" </dev/null
  fi || { echo "[x] Proses ${sub} gagal. Commit belum dicatat." >&2; return 1; }

  mkdir -p "$(dirname "$marker")" || return 1
  marker_tmp="${marker}.tmp.$$"
  printf '%s\n' "$commit" > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" && mv -f "$marker_tmp" "$marker" || { rm -f "$marker_tmp"; return 1; }
  echo "[+] Selesai: VPSNAT ${new_version} (${commit:0:12}). Jalankan: vpsnat"
)

vpsnat_get "$@"; exit $?
