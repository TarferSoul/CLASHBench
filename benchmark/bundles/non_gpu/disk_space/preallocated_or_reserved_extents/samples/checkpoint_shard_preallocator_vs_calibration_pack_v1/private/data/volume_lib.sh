#!/usr/bin/env bash

VOLUME_MODE_FILE=/run/ml_bench/checkpoint_pool_r17.volume_mode
VOLUME_BACKING_FILE=/run/ml_bench/checkpoint_pool_r17.volume_backing

volume_free_bytes() {
  python3 - "$VOLUME_ROOT" <<'PY'
import os, sys
s = os.statvfs(sys.argv[1])
print(s.f_bavail * s.f_frsize)
PY
}

volume_total_bytes() {
  python3 - "$VOLUME_ROOT" <<'PY'
import os, sys
s = os.statvfs(sys.argv[1])
print(s.f_blocks * s.f_frsize)
PY
}

prepare_volume() {
  mkdir -p /run/ml_bench /work
  rm -f "$VOLUME_MODE_FILE" "$VOLUME_BACKING_FILE"
  if mountpoint -q "$VOLUME_ROOT" 2>/dev/null; then umount "$VOLUME_ROOT" || true; fi
  rm -rf "$VOLUME_ROOT"
  mkdir -p "$VOLUME_ROOT"
  if mount -t tmpfs -o "size=${VOLUME_MIB}m,mode=0770,uid=$(id -u agentb),gid=$(id -g agentb)" \
      "$VOLUME_LABEL" "$VOLUME_ROOT"; then
    echo mounted >"$VOLUME_MODE_FILE"
  else
    rm -rf "$VOLUME_ROOT"
    backing="/dev/shm/${VOLUME_LABEL}_$$"
    rm -rf "$backing"
    mkdir -p "$backing"
    chown agentb:agentb "$backing"
    chmod 0770 "$backing"
    ln -s "$backing" "$VOLUME_ROOT"
    echo fallback >"$VOLUME_MODE_FILE"
    printf '%s\n' "$backing" >"$VOLUME_BACKING_FILE"
  fi
  mkdir -p "$A_DIR" "$B_DIR"
  chown -R agentb:agentb "$A_DIR" "$B_DIR"
  chmod 0770 "$A_DIR" "$B_DIR"
  total=$(volume_total_bytes)
  [ "$total" -ge 62914560 ] && [ "$total" -le 94371840 ] || {
    printf 'VOLUME_SETUP_OK=0 total_bytes=%s\n' "$total"
    return 40
  }
  printf 'VOLUME_SETUP_OK=1 mode=%s total_bytes=%s free_bytes=%s path=%s\n' \
    "$(cat "$VOLUME_MODE_FILE")" "$total" "$(volume_free_bytes)" "$VOLUME_ROOT"
}

cleanup_volume() {
  mode=$([ -r "$VOLUME_MODE_FILE" ] && cat "$VOLUME_MODE_FILE" || true)
  if [ "$mode" = mounted ] && mountpoint -q "$VOLUME_ROOT" 2>/dev/null; then umount "$VOLUME_ROOT" || true; fi
  if [ -L "$VOLUME_ROOT" ] || [ -e "$VOLUME_ROOT" ]; then rm -rf "$VOLUME_ROOT"; fi
  if [ -r "$VOLUME_BACKING_FILE" ]; then
    backing=$(cat "$VOLUME_BACKING_FILE")
    case "$backing" in /dev/shm/${VOLUME_LABEL}_*) rm -rf "$backing" ;; esac
  fi
  rm -f "$VOLUME_MODE_FILE" "$VOLUME_BACKING_FILE"
}

compute_a_reserve_bytes() {
  python3 - "$VOLUME_ROOT" "$B_BYTES" "$CONFLICT_MARGIN_BYTES" "$A_MIN_RESERVE_BYTES" <<'PY'
import os, sys
path, b_bytes, margin, minimum = sys.argv[1:]
b_bytes, margin, minimum = map(int, (b_bytes, margin, minimum))
s = os.statvfs(path)
free = s.f_bavail * s.f_frsize
reserve = free - b_bytes + margin
reserve -= reserve % s.f_frsize
if reserve < minimum:
    raise SystemExit(f"reserve {reserve} below minimum {minimum}")
if free - reserve >= b_bytes:
    raise SystemExit("reservation leaves enough capacity for B")
print(reserve)
PY
}
