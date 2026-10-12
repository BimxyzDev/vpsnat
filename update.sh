#!/usr/bin/env bash
# Fetch, test, and install the latest VPSNAT source from GitHub.
# This file is sourced by vpsnat; it can also be invoked directly with bash.

vpsnat_read_version() {
  local file="${1:-}"
  [[ -r "$file" ]] || return 1
  sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$file" | head -n1
}

vpsnat_update_main() (
  local mode="apply" force=0 repo branch api_url raw_url archive_url
  local work commit remote_version current_version installed_commit source_dir source_version
  while (($#)); do
    case "$1" in
      --check) mode="check" ;;
      --force) force=1 ;;
      -h|--help)
        cat <<'EOF'
Usage: vpsnat update [--check] [--force]

  --check  Fetch the latest version/commit metadata without installing it.
  --force  Reinstall the latest commit even if it is already installed.

The default source is BimxyzDev/vpsnat, branch main.
Override with VPSNAT_REPO=owner/repo and VPSNAT_BRANCH=branch.
EOF
        return 0
        ;;
      *) printf '[x] Argumen update tidak dikenal: %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done

  repo="${VPSNAT_REPO:-BimxyzDev/vpsnat}"
  branch="${VPSNAT_BRANCH:-main}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "[x] VPSNAT_REPO harus berbentuk owner/repo."; return 2; }
  [[ "$branch" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "[x] Nama branch tidak valid."; return 2; }
  if [[ "$mode" != "check" && "$EUID" -ne 0 ]]; then
    echo "[x] Update harus dijalankan sebagai root: sudo vpsnat update" >&2
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "[x] curl belum terpasang."; return 1; }
  command -v tar >/dev/null 2>&1 || { echo "[x] tar belum terpasang."; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "[x] Python 3 diperlukan untuk membaca metadata GitHub."; return 1; }

  work=$(mktemp -d) || { echo "[x] Tidak bisa membuat direktori sementara."; return 1; }
  trap 'rm -rf "$work"' EXIT
  api_url="https://api.github.com/repos/${repo}/commits/${branch}"
  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 2 "$api_url" -o "$work/commit.json"; then
    echo "[x] Gagal mengambil commit terbaru dari GitHub."
    return 1
  fi
  commit=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha", ""))' < "$work/commit.json") || return 1
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "[x] Respons GitHub tidak memuat SHA commit yang valid."; return 1; }

  raw_url="https://raw.githubusercontent.com/${repo}/${commit}/core.sh"
  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 "$raw_url" -o "$work/core.sh"; then
    echo "[x] Gagal mengambil metadata versi dari core.sh."
    return 1
  fi
  remote_version=$(vpsnat_read_version "$work/core.sh") || { echo "[x] VERSION tidak ditemukan di core.sh dari repo."; return 1; }
  [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "[x] Format VERSION dari repo tidak valid."; return 1; }
  current_version="${VERSION:-unknown}"
  installed_commit=""
  if [[ -r "${VPSNAT_COMMIT_FILE:-/etc/vpsnat/source.commit}" ]]; then
    IFS= read -r installed_commit < "${VPSNAT_COMMIT_FILE:-/etc/vpsnat/source.commit}" || true
  fi

  printf 'VPSNAT terpasang : %s\nVersi repo       : %s\nCommit repo      : %s\n' "$current_version" "$remote_version" "$commit"
  if [[ "$mode" == "check" ]]; then
    if [[ "$installed_commit" == "$commit" && "$current_version" == "$remote_version" ]]; then
      echo "[+] Source sudah di commit terbaru."
    else
      echo "[i] Update tersedia atau commit lokal belum tercatat. Jalankan: sudo vpsnat update"
    fi
    return 0
  fi
  if [[ "$force" -ne 1 && "$installed_commit" == "$commit" && "$current_version" == "$remote_version" ]]; then
    echo "[+] VPSNAT sudah menggunakan source terbaru."
    return 0
  fi

  archive_url="https://codeload.github.com/${repo}/tar.gz/${commit}"
  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 300 --retry 2 "$archive_url" -o "$work/source.tar.gz"; then
    echo "[x] Gagal mengunduh source archive dari GitHub."
    return 1
  fi
  source_dir="$work/source"
  mkdir -p "$source_dir" || return 1
  if ! tar -xzf "$work/source.tar.gz" --strip-components=1 --no-same-owner -C "$source_dir"; then
    echo "[x] Source archive tidak bisa diekstrak."
    return 1
  fi
  for required in vpsnat core.sh cli.sh install.sh update.sh test.sh; do
    [[ -s "$source_dir/$required" ]] || { printf '[x] Source repo tidak lengkap: %s\n' "$required"; return 1; }
  done
  source_version=$(vpsnat_read_version "$source_dir/core.sh") || return 1
  [[ "$source_version" == "$remote_version" ]] || { echo "[x] Versi metadata berbeda dengan source archive; update dibatalkan."; return 1; }

  echo "[i] Menjalankan tes regresi sebelum pemasangan..."
  if ! bash "$source_dir/test.sh"; then
    echo "[x] Tes gagal. Source terpasang tidak diubah."
    return 1
  fi
  echo "[i] Memasang VPSNAT ${source_version} dari commit ${commit}..."
  if ! VPSNAT_APP_DIR="$source_dir" bash "$source_dir/vpsnat" upgrade; then
    echo "[x] Proses upgrade gagal. Periksa log; source commit belum diperbarui."
    return 1
  fi

  local marker="${VPSNAT_COMMIT_FILE:-/etc/vpsnat/source.commit}" marker_tmp
  mkdir -p "$(dirname "$marker")" || return 1
  marker_tmp="${marker}.tmp.$$"
  printf '%s\n' "$commit" > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  mv -f "$marker_tmp" "$marker" || { rm -f "$marker_tmp"; return 1; }
  echo "[+] Update selesai: VPSNAT ${source_version} (${commit:0:12})."
)

vpsnat_update() {
  ( vpsnat_update_main "$@" )
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _update_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -z "${VERSION:-}" && -r "$_update_dir/core.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_update_dir/core.sh"
  fi
  vpsnat_update "$@"
fi
