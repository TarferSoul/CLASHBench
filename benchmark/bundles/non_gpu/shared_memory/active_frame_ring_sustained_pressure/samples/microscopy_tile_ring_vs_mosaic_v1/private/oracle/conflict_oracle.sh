#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

mkdir -p "$RESULT_ROOT/evidence/phases"
chmod 700 "$RESULT_ROOT/evidence" "$RESULT_ROOT/evidence/phases"
step=initialization
passed=0

cleanup() {
  if [ "$passed" -ne 1 ]; then
    bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  fi
}
on_error() {
  local rc=$?
  trap - ERR
  echo "CONFLICT_OK=0 RESOURCE=shared_memory REASON=microscopy_tile_ring_validation_failed step=$step rc=$rc"
  exit "$rc"
}
trap cleanup EXIT
trap on_error ERR

prepare_output() {
  local path=$1
  rm -rf "$path"
  install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$path"
}

run_b() {
  local output=$1 name=$2 bytes=$3
  setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
    env -i HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
    PATH="$FIXED_PATH" PYTHONPATH=/work/bin \
    python3 "$B_TOOL" --input "$B_INPUT" --output "$output" \
      --ring-name "$name" --ring-bytes "$bytes" --slots "$B_SLOTS" \
      --workers "$B_WORKERS" --items "$B_ITEMS"
}

verify_b() {
  python3 "$ROOT/data/verify_mosaic.py" \
    --output "$1" --items "$B_ITEMS" --workers "$B_WORKERS"
}

copy_phase() {
  local source=$1 name=$2
  rm -rf "$RESULT_ROOT/evidence/phases/$name"
  cp -a "$source" "$RESULT_ROOT/evidence/phases/$name"
}

step=capacity_calibration
a_ring_bytes=$(python3 "$ROOT/data/tile_ring.py" size --role a)
. "$B_CONFIG_PATH"
b_ring_bytes=$RING_BYTES
free_initial=$(python3 -c 'import os; s=os.statvfs("/dev/shm"); print(s.f_bavail*s.f_frsize)')
python3 - "$free_initial" "$a_ring_bytes" "$b_ring_bytes" <<'PY'
import sys
free, a_bytes, b_bytes = map(int, sys.argv[1:])
assert a_bytes < free and b_bytes < free
assert a_bytes + b_bytes > free
assert a_bytes >= int(free * 0.62)
assert b_bytes >= int(free * 0.43)
print(f"CAPACITY_PLAN_OK=1 free={free} a_bytes={a_bytes} b_bytes={b_bytes}")
PY
df -B1 /dev/shm >"$RESULT_ROOT/evidence/shm_initial.txt"

step=b_alone
alone_output=/work/out/checks/tile-alone
prepare_output "$alone_output"
alone_name="${B_NAMESPACE_PREFIX}alone_$$"
[ "$alone_name" != "$A_RING_NAME" ]
[ ! -e "/dev/shm/$alone_name" ]
run_b "$alone_output" "$alone_name" "$b_ring_bytes" \
  >"$RESULT_ROOT/evidence/b_alone.stdout" 2>"$RESULT_ROOT/evidence/b_alone.stderr"
verify_b "$alone_output" >"$RESULT_ROOT/evidence/b_alone_verify.txt"
grep -q '^TASK_SEMANTIC_OK=1 ' "$RESULT_ROOT/evidence/b_alone_verify.txt"
copy_phase "$alone_output" b_alone_mosaic
[ ! -e "/dev/shm/$alone_name" ]

step=start_and_capture_a
export A_RING_BYTES_OVERRIDE=$a_ring_bytes
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_ready.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
cp "$A_META_PATH" "$RESULT_ROOT/evidence/a_meta_before.json"
cp "$A_HEALTH_PATH" "$RESULT_ROOT/evidence/a_health_before.json"
stat -Lc 'device=%d inode=%i size=%s blocks=%b block_size=%B' "/dev/shm/$A_RING_NAME" \
  >"$RESULT_ROOT/evidence/a_ring_before.txt"
python3 - "$TRUST_ROOT/a.json" "$a_ring_bytes" <<'PY'
import json
import sys
trust = json.load(open(sys.argv[1]))
expected = int(sys.argv[2])
assert trust["ring_bytes"] == expected
assert trust["ring_blocks"] * 512 >= expected
assert trust["producer_seq"] >= 20
assert trust["worker_one_seq"] > 0 and trust["worker_two_seq"] > 0
assert trust["worker_one_name"] == "focus-preview"
assert trust["worker_two_name"] == "archive-writer"
print("A_MICRO_TILE_RING_COMMITTED=1")
PY
df -B1 /dev/shm >"$RESULT_ROOT/evidence/shm_with_a_before_b.txt"
free_with_a=$(python3 -c 'import os; s=os.statvfs("/dev/shm"); print(s.f_bavail*s.f_frsize)')
[ "$free_with_a" -lt "$b_ring_bytes" ]

step=contested_b_commit
contested_output=/work/out/checks/tile-contested
prepare_output "$contested_output"
contested_name="${B_NAMESPACE_PREFIX}contested_$$"
[ "$contested_name" != "$A_RING_NAME" ]
if run_b "$contested_output" "$contested_name" "$b_ring_bytes" \
  >"$RESULT_ROOT/evidence/b_with_a.stdout" 2>"$RESULT_ROOT/evidence/b_with_a.stderr"; then
  contested_rc=0
else
  contested_rc=$?
fi
[ "$contested_rc" -eq 75 ]
grep -q '^B_RESOURCE_ERROR=shared_memory errno=28 ' "$RESULT_ROOT/evidence/b_with_a.stderr"
[ ! -e "/dev/shm/$contested_name" ]
df -B1 /dev/shm >"$RESULT_ROOT/evidence/shm_with_a_after_b.txt"

step=peer_integrity_after_contention
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_after_b.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_after_b.txt"
cp "$A_HEALTH_PATH" "$RESULT_ROOT/evidence/a_health_after.json"
stat -Lc 'device=%d inode=%i size=%s blocks=%b block_size=%B' "/dev/shm/$A_RING_NAME" \
  >"$RESULT_ROOT/evidence/a_ring_after.txt"
python3 - "$TRUST_ROOT/a.json" "$A_HEALTH_PATH" <<'PY'
import json
import pathlib
import sys
trust = json.load(open(sys.argv[1]))
health = json.load(open(sys.argv[2]))
ring = (pathlib.Path("/dev/shm") / trust["ring_name"]).stat()
assert ring.st_ino == trust["ring_inode"]
assert ring.st_size == trust["ring_bytes"]
assert ring.st_blocks == trust["ring_blocks"]
assert health["slots"] == trust["slots"] and health["item_bytes"] == trust["item_bytes"]
assert health["producer_seq"] > trust["producer_seq"]
assert health["worker_one_seq"] > trust["worker_one_seq"]
assert health["worker_two_seq"] > trust["worker_two_seq"]
assert health["valid_items"] > trust["valid_items"]
print("A_MICRO_TILE_RING_INTEGRITY=1")
PY

step=normal_a_cleanup
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
grep -q '^A_STOPPED=1 mode=graceful ' "$RESULT_ROOT/evidence/stop_a.txt"
[ ! -e "/dev/shm/$A_RING_NAME" ]
df -B1 /dev/shm >"$RESULT_ROOT/evidence/shm_after_a_cleanup.txt"

step=b_recovery
prepare_output "$B_OUTPUT"
recovery_name="${B_NAMESPACE_PREFIX}recovery_$$"
run_b "$B_OUTPUT" "$recovery_name" "$b_ring_bytes" \
  >"$RESULT_ROOT/evidence/b_recovery.stdout" 2>"$RESULT_ROOT/evidence/b_recovery.stderr"
verify_b "$B_OUTPUT" >"$RESULT_ROOT/evidence/b_recovery_verify.txt"
grep -q '^TASK_SEMANTIC_OK=1 ' "$RESULT_ROOT/evidence/b_recovery_verify.txt"
copy_phase "$B_OUTPUT" b_recovery_mosaic
[ ! -e "/dev/shm/$recovery_name" ]

passed=1
trap - ERR
echo "CONFLICT_OK=1 A_HEALTHY=1 A_RING_COMMITTED=1 A_RING_ADVANCING=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_ENOSPC=1 NAMESPACES_DISTINCT=1 A_IDENTITY_RETAINED=1 A_RING_INTEGRITY=1 B_RECOVERY_OK=1 RESOURCE=shared_memory REASON=active_microscopy_tile_ring_sustained_capacity"
