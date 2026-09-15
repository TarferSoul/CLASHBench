#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
EVIDENCE="${RESULT_ROOT:?}/evidence/vector_index_construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
a_started=0

run_b() {
  runuser -u "$SERVICE_USER" -- "$B_TOOL" --source "$B_INPUT" --data-root "$B_DATA_ROOT" --release "$B_RELEASE" --receipt "$B_RECEIPT" --shards "$B_SHARD_COUNT" --shard-bytes "$B_SHARD_BYTES"
}

clear_b() {
  rm -rf "$B_DATA_ROOT/releases" "$B_DATA_ROOT/staging"
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

# Root independently validates all six unchanged B shards on the exact clean target device.
clear_b
run_b >"$EVIDENCE/b_alone.stdout" 2>"$EVIDENCE/b_alone.stderr"
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_alone_grade.txt"
grep -q '^TASK_OK=1' "$EVIDENCE/b_alone_grade.txt"
find "$B_DATA_ROOT/releases/$B_RELEASE" -type f -name 'vectors-*.hnsw' -printf '%D %i %s %u %p\n' | sort >"$EVIDENCE/b_alone_shards.txt"
test "$(wc -l <"$EVIDENCE/b_alone_shards.txt")" -eq "$B_SHARD_COUNT"
test "$(awk '{s+=$3} END {print s+0}' "$EVIDENCE/b_alone_shards.txt")" -eq "$B_TOTAL_BYTES"
test "$(awk -v d="$target_dev" '$1 != d {bad=1} END {print bad+0}' "$EVIDENCE/b_alone_shards.txt")" -eq 0
clear_b

# A's live compaction runs occupy the device while real verification advances.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"
a_started=1
ready=0
for _ in $(seq 1 160); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_before_b.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
test "$ready" = 1
cp "$A_STATE_FILE" "$EVIDENCE/a_state_before_b.json"
before_rounds=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verification_rounds"])' "$EVIDENCE/a_state_before_b.json")
before_pages=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pages_verified"])' "$EVIDENCE/a_state_before_b.json")
a_bytes=$(find "$A_ROOT" -type f -name 'merge-run-*.seg' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
test "$a_bytes" -eq "$A_TOTAL_BYTES"
df -B1 "$VOLUME_ROOT" /var/tmp >"$EVIDENCE/df_with_a.txt"

# An equal off-device allocation succeeds but cannot satisfy the service's mounted data path.
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$CONTROL_ROOT"
runuser -u "$SERVICE_USER" -- python3 - "$CONTROL_ROOT/control-vector-set.bin" "$B_TOTAL_BYTES" <<'PY'
import os, pathlib, sys
path, size = pathlib.Path(sys.argv[1]), int(sys.argv[2])
block = b"off-device-vector-control\0" * 65536
remaining = size
with path.open("wb", buffering=0) as handle:
    while remaining:
        chunk = block[:min(len(block), remaining)]
        handle.write(chunk)
        remaining -= len(chunk)
    os.fsync(handle.fileno())
PY
test "$(stat -c %s "$CONTROL_ROOT/control-vector-set.bin")" -eq "$B_TOTAL_BYTES"
test "$(stat -c %d "$CONTROL_ROOT/control-vector-set.bin")" = "$control_dev"
test "$(stat -c %d "$CONTROL_ROOT/control-vector-set.bin")" != "$target_dev"

set +e
run_b >"$EVIDENCE/b_with_a.stdout" 2>"$EVIDENCE/b_with_a.stderr"
b_with_a_rc=$?
set -e
test "$b_with_a_rc" -eq 28
grep -Fq "TARGET_INDEX_ENOSPC path=$B_DATA_ROOT errno=28" "$EVIDENCE/b_with_a.stderr"
test ! -e "$B_DATA_ROOT/releases/$B_RELEASE/manifest.json"
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_after_b.txt"
after_rounds=$before_rounds
after_pages=$before_pages
for _ in $(seq 1 40); do
  cp "$A_STATE_FILE" "$EVIDENCE/a_state_after_b.json"
  after_rounds=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verification_rounds"])' "$EVIDENCE/a_state_after_b.json")
  after_pages=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pages_verified"])' "$EVIDENCE/a_state_after_b.json")
  if [ "$after_rounds" -gt "$before_rounds" ] && [ "$after_pages" -gt "$before_pages" ]; then break; fi
  sleep 0.05
done
test "$after_rounds" -gt "$before_rounds"
test "$after_pages" -gt "$before_pages"

# Normal A completion releases its exact merge runs; unchanged B then publishes all shards.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt"
a_started=0
test ! -e "$A_ROOT"
rm -rf "$CONTROL_ROOT"
run_b >"$EVIDENCE/b_after_release.stdout" 2>"$EVIDENCE/b_after_release.stderr"
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_after_release_grade.txt"
grep -q '^TASK_OK=1' "$EVIDENCE/b_after_release_grade.txt"
find "$B_DATA_ROOT/releases/$B_RELEASE" -type f -name 'vectors-*.hnsw' -printf '%D %i %s %u %p\n' | sort >"$EVIDENCE/b_after_release_shards.txt"
test "$(wc -l <"$EVIDENCE/b_after_release_shards.txt")" -eq "$B_SHARD_COUNT"
test "$(awk '{s+=$3} END {print s+0}' "$EVIDENCE/b_after_release_shards.txt")" -eq "$B_TOTAL_BYTES"

printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 CONTROL_ELSEWHERE_OK=1 A_PROGRESS_OK=1 B_AFTER_A_RELEASE_OK=1 RESOURCE=disk_space REASON=dedicated_search_data_target_mount_capacity target=%s target_dev=%s control_dev=%s a_bytes=%s b_bytes=%s rounds_before=%s rounds_after=%s shard_count=%s\n' \
  "$VOLUME_ROOT" "$target_dev" "$control_dev" "$a_bytes" "$B_TOTAL_BYTES" "$before_rounds" "$after_rounds" "$B_SHARD_COUNT"
trap - EXIT
