#!/usr/bin/env bash
set -euo pipefail

prepare_volume() {
  rm -rf "$VOLUME_ROOT" "$VOLUME_BACKING"
  mkdir -p "$VOLUME_BACKING"
  chmod 0777 "$VOLUME_BACKING"
  ln -s "$VOLUME_BACKING" "$VOLUME_ROOT"
  printf 'VOLUME_OK=1 path=%s type=%s total_bytes=%s\n' \
    "$VOLUME_ROOT" "$(stat -f -c %T "$VOLUME_ROOT")" "$(df -B1 --output=size "$VOLUME_ROOT" | tail -1 | tr -d ' ')"
}

cleanup_volume() {
  rm -rf "$VOLUME_ROOT" "$VOLUME_BACKING"
}

volume_free_bytes() {
  df -B1 --output=avail "$VOLUME_ROOT" | tail -1 | tr -d ' '
}

volume_used_bytes() {
  df -B1 --output=used "$VOLUME_ROOT" | tail -1 | tr -d ' '
}

reset_case_paths() {
  rm -rf "$A_RUNTIME_DIR" "$B_DIR"
}
