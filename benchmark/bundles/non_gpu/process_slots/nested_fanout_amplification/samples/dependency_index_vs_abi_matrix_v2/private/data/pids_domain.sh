#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
STATE_FILE=${PID_DOMAIN_STATE_FILE:?}
MOUNT_ROOT=${PID_DOMAIN_MOUNT:?}

setup_domain() {
  mkdir -p "$MOUNT_ROOT"
  mount -t cgroup2 -o rw none "$MOUNT_ROOT"
  local baseline original target
  baseline=$(cat "$MOUNT_ROOT/pids.current")
  original=$(cat "$MOUNT_ROOT/pids.max")
  if [ "$original" != max ] && [ "$original" -lt "$baseline" ]; then
    echo "PID_DOMAIN_FAIL=invalid_original_limit baseline=$baseline original=$original" >&2
    exit 1
  fi
  target=$((baseline + PID_DOMAIN_HEADROOM))
  if [ "$original" != max ] && [ "$target" -gt "$original" ]; then
    target=$original
  fi
  if [ "$target" -le "$baseline" ]; then
    echo "PID_DOMAIN_FAIL=no_headroom baseline=$baseline target=$target" >&2
    exit 1
  fi
  printf '%s\n' "$target" > "$MOUNT_ROOT/pids.max"
  if [ "$(cat "$MOUNT_ROOT/pids.max")" != "$target" ]; then
    echo "PID_DOMAIN_FAIL=limit_write_not_observed" >&2
    exit 1
  fi
  install -d -o root -g root -m 0700 "$(dirname "$STATE_FILE")"
  {
    printf 'PID_DOMAIN_MOUNT=%q\n' "$MOUNT_ROOT"
    printf 'PID_DOMAIN_BASELINE=%q\n' "$baseline"
    printf 'PID_DOMAIN_ORIGINAL_MAX=%q\n' "$original"
    printf 'PID_DOMAIN_APPLIED_MAX=%q\n' "$target"
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
  echo "PID_DOMAIN_READY=1 baseline=$baseline pids_max=$target original=$original mount=$MOUNT_ROOT"
}

restore_domain() {
  [ -s "$STATE_FILE" ] || exit 0
  . "$STATE_FILE"
  if [ "${PID_DOMAIN_ORIGINAL_MAX:-max}" = max ]; then
    printf '%s\n' max > "$PID_DOMAIN_MOUNT/pids.max" 2>/dev/null || true
  else
    printf '%s\n' "$PID_DOMAIN_ORIGINAL_MAX" > "$PID_DOMAIN_MOUNT/pids.max" 2>/dev/null || true
  fi
  umount "$PID_DOMAIN_MOUNT" 2>/dev/null || true
  rm -f "$STATE_FILE"
  rmdir "$PID_DOMAIN_MOUNT" 2>/dev/null || true
  echo "PID_DOMAIN_RESTORED=1 original=$PID_DOMAIN_ORIGINAL_MAX"
}

case "${1:-}" in
  setup) setup_domain ;;
  restore|cleanup) restore_domain ;;
  *) echo "usage: pids_domain.sh setup|restore" >&2; exit 2 ;;
esac
