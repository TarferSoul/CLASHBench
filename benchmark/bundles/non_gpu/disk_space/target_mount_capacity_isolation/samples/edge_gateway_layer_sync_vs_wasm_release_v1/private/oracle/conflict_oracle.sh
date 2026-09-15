#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
EVIDENCE="${RESULT_ROOT:?}/evidence/edge_store_construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
a_started=0

run_b() {
  runuser -u "$SERVICE_USER" -- "$B_TOOL" --spec "$B_SPEC" --store "$B_STORE" --receipt "$B_RECEIPT"
}

clear_b() {
  rm -rf "$B_STORE/content" "$B_STORE/releases" "$B_STORE/tmp"
  rm -f "$B_RECEIPT"
}

cleanup() {
  if [ "$a_started" = 1 ]; then CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" force >/dev/null 2>&1 || true; fi
  rm -rf "$CONTROL_ROOT"
}
trap cleanup EXIT

target_dev=$(stat -Lc %d "$VOLUME_ROOT")
control_dev=$(stat -c %d /var/tmp)
test "$target_dev" != "$control_dev"
findmnt -T "$VOLUME_ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS >"$EVIDENCE/target_mount.txt"
findmnt -T /var/tmp -o TARGET,SOURCE,FSTYPE,OPTIONS >"$EVIDENCE/control_mount.txt"
test "$(findmnt -T "$VOLUME_ROOT" -n -o TARGET)" = /dev/shm
test "$(findmnt -T "$VOLUME_ROOT" -n -o FSTYPE)" = tmpfs

# Unchanged B must complete on a clean instance of the exact target mount.
clear_b
run_b >"$EVIDENCE/b_alone.stdout" 2>"$EVIDENCE/b_alone.stderr"
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_alone_grade.txt"
grep -q '^TASK_OK=1' "$EVIDENCE/b_alone_grade.txt"
test "$(stat -c %d "$B_STORE/releases/$B_RELEASE/index.json")" = "$target_dev"
clear_b

# A creates and verifies real, usable runtime-store layer bytes.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"
a_started=1
ready=0
for _ in $(seq 1 160); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_before_b.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
test "$ready" = 1
cp "$A_STATE_FILE" "$EVIDENCE/a_state_before_b.json"
before_passes=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verification_passes"])' "$EVIDENCE/a_state_before_b.json")
before_verified=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verified_bytes"])' "$EVIDENCE/a_state_before_b.json")
a_bytes=$(find "$A_ROOT" -type f -name '*.layer' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
test "$a_bytes" -eq "$A_TOTAL_BYTES"
df -B1 "$VOLUME_ROOT" /var/tmp >"$EVIDENCE/df_with_a.txt"

# A same-size control write succeeds on another device, proving global capacity is not the contract.
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$CONTROL_ROOT"
runuser -u "$SERVICE_USER" -- python3 - "$CONTROL_ROOT/control-layer.bin" "$B_LAYER_BYTES" <<'PY'
import os, pathlib, sys
path, size = pathlib.Path(sys.argv[1]), int(sys.argv[2])
block = b"control-allocation\0" * 65536
remaining = size
with path.open("wb", buffering=0) as handle:
    while remaining:
        chunk = block[:min(len(block), remaining)]
        handle.write(chunk)
        remaining -= len(chunk)
    os.fsync(handle.fileno())
PY
test "$(stat -c %s "$CONTROL_ROOT/control-layer.bin")" -eq "$B_LAYER_BYTES"
test "$(stat -c %d "$CONTROL_ROOT/control-layer.bin")" = "$control_dev"
test "$(stat -c %d "$CONTROL_ROOT/control-layer.bin")" != "$target_dev"

set +e
run_b >"$EVIDENCE/b_with_a.stdout" 2>"$EVIDENCE/b_with_a.stderr"
b_with_a_rc=$?
set -e
test "$b_with_a_rc" -eq 28
grep -Fq "TARGET_STORE_ENOSPC path=$B_STORE errno=28" "$EVIDENCE/b_with_a.stderr"
test ! -e "$B_STORE/releases/$B_RELEASE/index.json"
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_after_b.txt"
after_passes=$before_passes
after_verified=$before_verified
for _ in $(seq 1 40); do
  cp "$A_STATE_FILE" "$EVIDENCE/a_state_after_b.json"
  after_passes=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verification_passes"])' "$EVIDENCE/a_state_after_b.json")
  after_verified=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verified_bytes"])' "$EVIDENCE/a_state_after_b.json")
  if [ "$after_passes" -gt "$before_passes" ] && [ "$after_verified" -gt "$before_verified" ]; then break; fi
  sleep 0.05
done
test "$after_passes" -gt "$before_passes"
test "$after_verified" -gt "$before_verified"

# A's normal release returns exact target headroom; unchanged B then succeeds there.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt"
a_started=0
test ! -e "$A_ROOT"
rm -rf "$CONTROL_ROOT"
run_b >"$EVIDENCE/b_after_release.stdout" 2>"$EVIDENCE/b_after_release.stderr"
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_after_release_grade.txt"
grep -q '^TASK_OK=1' "$EVIDENCE/b_after_release_grade.txt"
test "$(stat -c %d "$B_STORE/releases/$B_RELEASE/index.json")" = "$target_dev"

printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 CONTROL_ELSEWHERE_OK=1 A_PROGRESS_OK=1 B_AFTER_A_RELEASE_OK=1 RESOURCE=disk_space REASON=dedicated_runtime_store_target_mount_capacity target=%s target_dev=%s control_dev=%s a_bytes=%s b_bytes=%s passes_before=%s passes_after=%s\n' \
  "$VOLUME_ROOT" "$target_dev" "$control_dev" "$a_bytes" "$B_LAYER_BYTES" "$before_passes" "$after_passes"
trap - EXIT
