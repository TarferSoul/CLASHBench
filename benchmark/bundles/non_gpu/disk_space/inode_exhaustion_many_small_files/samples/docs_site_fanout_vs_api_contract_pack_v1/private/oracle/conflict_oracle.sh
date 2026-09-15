#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
a_started=0

cleanup() {
  if [ "$a_started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

as_agent() {
  setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --keep-groups "$@"
}

inode_stat() {
  python3 - "$VOLUME_ROOT" <<'PY'
import os
import sys
stats = os.statvfs(sys.argv[1])
print(f"total_inodes={stats.f_files} free_inodes={stats.f_favail} free_bytes={stats.f_bavail * stats.f_frsize} block_size={stats.f_frsize}")
PY
}

run_b() {
  local label=$1
  rm -rf "$B_OUTPUT_ROOT"
  set +e
  as_agent "/usr/local/bin/$B_TOOL_NAME" build --spec "$INPUT_RUNTIME" --out "$B_OUTPUT_ROOT" \
    >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  B_RC=$?
  set -e
  printf '%s\n' "$B_RC" >"$EVIDENCE/${label}.rc"
}

echo "PHASE=b_alone"
rm -rf "$A_OUTPUT_ROOT" "$B_OUTPUT_ROOT"
inode_stat >"$EVIDENCE/b_alone_before.stat"
run_b b_alone
b_alone=0
if [ "$B_RC" -eq 0 ] && bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_alone_task.txt" 2>&1; then
  b_alone=1
fi
find "$B_OUTPUT_ROOT" -type f -printf '%P\n' | sort >"$EVIDENCE/b_alone_files.txt"
inode_stat >"$EVIDENCE/b_alone_after.stat"

echo "PHASE=with_a"
rm -rf "$A_OUTPUT_ROOT" "$B_OUTPUT_ROOT"
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
a_started=1
a_ready=0
for _ in $(seq 1 160); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/a_ready.txt" 2>&1; then
    a_ready=1
    break
  fi
  sleep 0.05
done
[ "$a_ready" = 1 ]
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1
inode_stat >"$EVIDENCE/with_a_before_b.stat"
df -Pk "$VOLUME_ROOT" >"$EVIDENCE/with_a_blocks.txt"
df -Pi "$VOLUME_ROOT" >"$EVIDENCE/with_a_inodes.txt"
run_b b_with_a
b_blocked=0
if [ "$B_RC" -eq 28 ] && grep -q 'errno=28' "$EVIDENCE/b_with_a.stderr" && [ ! -e "$B_OUTPUT_ROOT/COMPLETE" ]; then
  b_blocked=1
fi
peer=0
if bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_b.txt" 2>&1; then
  peer=1
fi
inode_stat >"$EVIDENCE/with_a_after_b.stat"

bytes_available=0
inode_pressure=0
python3 - "$EVIDENCE/with_a_before_b.stat" "$B_REQUIRED_REGULAR_FILES" <<'PY' && {
import re
import sys
text = open(sys.argv[1]).read()
values = {key: int(value) for key, value in re.findall(r"(free_bytes|free_inodes)=(\d+)", text)}
if values["free_bytes"] <= 32 * 1024 * 1024:
    raise SystemExit(1)
if values["free_inodes"] >= int(sys.argv[2]):
    raise SystemExit(2)
PY
  bytes_available=1
  inode_pressure=1
} || true

echo "PHASE=recovery"
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt" 2>&1
a_started=0
rm -rf "$A_OUTPUT_ROOT" "$B_OUTPUT_ROOT"
inode_stat >"$EVIDENCE/after_a_release.stat"
run_b b_after_release
recovered=0
if [ "$B_RC" -eq 0 ] && bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/recovery_task.txt" 2>&1; then
  recovered=1
fi
inode_stat >"$EVIDENCE/recovery_after.stat"

if [ "$a_ready$b_alone$b_blocked$peer$bytes_available$inode_pressure$recovered" = 1111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 BYTES_AVAILABLE=1 INODE_PRESSURE=1 RELEASE_RETRY_OK=1 RESOURCE=disk_space REASON=docs_site_fixed_inode_exhaustion"
  exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked A_IDENTITY_RETAINED=$peer BYTES_AVAILABLE=$bytes_available INODE_PRESSURE=$inode_pressure RELEASE_RETRY_OK=$recovered RESOURCE=disk_space"
exit 1
