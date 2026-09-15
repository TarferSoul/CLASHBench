#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test "$(id -u "$SERVICE_USER")" -gt 0
test -x "$A_TOOL"
test -x "$B_TOOL"
test -r "$B_INPUT"
test -L "$VOLUME_ROOT"
test "$(findmnt -T "$VOLUME_ROOT" -n -o TARGET)" = /dev/shm
test "$(findmnt -T "$VOLUME_ROOT" -n -o FSTYPE)" = tmpfs
runuser -u "$SERVICE_USER" -- test -w "$VOLUME_ROOT"
target_dev=$(stat -Lc %d "$VOLUME_ROOT")
control_dev=$(stat -c %d /var/tmp)
test "$target_dev" != "$control_dev"
available=$(df --output=avail -B1 "$VOLUME_ROOT" | tail -1 | tr -d ' ')
test "$available" -gt "$B_TOTAL_BYTES"
printf 'PREFLIGHT_OK=1 target=%s target_dev=%s control_dev=%s available=%s input_lines=%s\n' "$VOLUME_ROOT" "$target_dev" "$control_dev" "$available" "$(wc -l <"$B_INPUT")"
