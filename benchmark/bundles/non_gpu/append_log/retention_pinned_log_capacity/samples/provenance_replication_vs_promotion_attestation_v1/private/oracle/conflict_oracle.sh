#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"
started=0

cleanup() {
  if [ "$started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

commit_file="$RESULT_ROOT/evidence/promotion_receipt.json"
run_b() {
  rm -f "$commit_file"
  "$JOURNAL_APPEND" \
    --store "$STORE_ROOT" \
    --input "$B_INPUT" \
    --transaction "$B_TRANSACTION" \
    --commit "$commit_file"
}

verify_b() {
  B_COMMIT_OVERRIDE="$commit_file" bash "$ROOT/eval/task_check_b.sh" | grep -q '^TASK_OK=1 '
}

# Phase 1: prove the exact requested transaction can reserve space and commit alone.
b_alone=0
if run_b >"$RESULT_ROOT/evidence/b_alone.txt" 2>&1 && verify_b; then
  b_alone=1
fi
cp "$commit_file" "$RESULT_ROOT/evidence/b_alone_commit.json" 2>/dev/null || true
python3 "$JOURNAL_LIB" inventory --store "$STORE_ROOT" >"$RESULT_ROOT/evidence/b_alone_inventory.json"

# Phase 2: restore the store, run the useful producer and shipper, and capture trust.
bash "$ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight_joint.txt" 2>&1
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
started=1
bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_before.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
python3 "$JOURNAL_LIB" inventory --store "$STORE_ROOT" >"$RESULT_ROOT/evidence/capacity_before_b.json"
cp "$STORE_ROOT/config.json" "$RESULT_ROOT/evidence/config_before_b.json"
cp "$STORE_ROOT/manifest.json" "$RESULT_ROOT/evidence/manifest_before_b.json"
df -Pk "$STORE_ROOT" >"$RESULT_ROOT/evidence/df_before_b.txt"
cp /proc/meminfo "$RESULT_ROOT/evidence/meminfo_before_b.txt"
cp /proc/loadavg "$RESULT_ROOT/evidence/loadavg_before_b.txt"
ps -eo pid,ppid,pgid,euid,stat,%cpu,%mem,comm,args >"$RESULT_ROOT/evidence/ps_before_b.txt"

# Phase 3: unchanged B must fail specifically on configured segment capacity.
set +e
run_b >"$RESULT_ROOT/evidence/b_with_a.txt" 2>&1
joint_rc=$?
set -e
b_capacity_blocked=0
if [ "$joint_rc" = 75 ] && grep -q '^CAPACITY_EXCEEDED ' "$RESULT_ROOT/evidence/b_with_a.txt" && [ ! -e "$commit_file" ]; then
  if ! python3 "$JOURNAL_LIB" contains --store "$STORE_ROOT" --transaction "$B_TRANSACTION" \
      >"$RESULT_ROOT/evidence/b_presence_with_a.txt" 2>&1; then
    b_capacity_blocked=1
  fi
fi

capacity_measured=0
if python3 - "$RESULT_ROOT/evidence/capacity_before_b.json" "$JOURNAL_LIB" "$STORE_ROOT" "$B_INPUT" "$B_TRANSACTION" <<'PY'
import importlib.util
import json
import pathlib
import sys

inventory = json.loads(pathlib.Path(sys.argv[1]).read_text())
spec = importlib.util.spec_from_file_location("bounded_journal", sys.argv[2])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
journal = module.Journal(sys.argv[3])
required = journal.measure(module.load_records(sys.argv[4]), sys.argv[5])
assert inventory["allocated_bytes"] == inventory["capacity_bytes"] == 49152
assert inventory["segment_bytes"] == 12288
assert inventory["pinned_segment_count"] >= 3
assert inventory["pinned_bytes"] >= 36864
assert inventory["active_remaining_bytes"] < required <= inventory["segment_bytes"]
print(
    "CAPACITY_MEASURED=1 capacity_bytes=%d allocated_bytes=%d pinned_bytes=%d active_remaining_bytes=%d required_bytes=%d"
    % (
        inventory["capacity_bytes"],
        inventory["allocated_bytes"],
        inventory["pinned_bytes"],
        inventory["active_remaining_bytes"],
        required,
    )
)
PY
then
  capacity_measured=1
fi

peer=0
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_with_a.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_with_a.txt" && peer=1
python3 "$JOURNAL_LIB" inventory --store "$STORE_ROOT" >"$RESULT_ROOT/evidence/capacity_after_blocked_b.json"
cp "$STORE_ROOT/manifest.json" "$RESULT_ROOT/evidence/manifest_after_blocked_b.json"

alternatives_excluded=0
if python3 - "$STORE_ROOT" "$CAPACITY_BYTES" <<'PY'
import os
import pathlib
import sys

store = pathlib.Path(sys.argv[1])
capacity = int(sys.argv[2])
stat = os.statvfs(store)
disk_free = stat.f_bavail * stat.f_frsize
meminfo = {}
for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
    key, value = line.split(":", 1)
    meminfo[key] = int(value.strip().split()[0]) * 1024
assert disk_free > capacity * 32
assert meminfo["MemAvailable"] > 64 * 1024 * 1024
print(f"ALTERNATIVES_EXCLUDED=1 disk_free_bytes={disk_free} mem_available_bytes={meminfo['MemAvailable']}")
PY
then
  alternatives_excluded=1
fi

# Phase 4: acknowledge the exact trusted archive copy, then retry unchanged B.
read -r release_segment release_digest release_archive < <(
  python3 - "$A_TRUST_FILE" <<'PY'
import json
import sys
item = json.load(open(sys.argv[1]))["pinned"][0]
print(item["segment_id"], item["sha256"], item["archive_copy"])
PY
)
"$JOURNAL_ACK" --store "$STORE_ROOT" --segment "$release_segment" --digest "$release_digest" \
  --archive-copy "$release_archive" >"$RESULT_ROOT/evidence/replica_ack.txt" 2>&1
python3 "$JOURNAL_LIB" inventory --store "$STORE_ROOT" >"$RESULT_ROOT/evidence/capacity_after_ack.json"

exact_pin_released=0
if python3 - "$A_TRUST_FILE" "$RESULT_ROOT/evidence/capacity_after_ack.json" "$release_segment" <<'PY'
import json
import pathlib
import sys

trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
after = json.loads(pathlib.Path(sys.argv[2]).read_text())
released = sys.argv[3]
assert after["ack_generation"] == trust["ack_generation"] + 1
assert after["allocated_bytes"] == trust["allocated_bytes"] - trust["segment_bytes"]
current = {item["segment_id"]: item for item in after["segments"]}
assert released not in current
for item in trust["pinned"]:
    if item["segment_id"] == released:
        continue
    present = current[item["segment_id"]]
    assert present["retention_pinned"]
    assert (present["current_device"], present["current_inode"]) == (item["device"], item["inode"])
    assert present["logical_sha256"] == item["sha256"]
print(f"EXACT_PIN_RELEASED=1 segment={released} freed_bytes={trust['segment_bytes']}")
PY
then
  exact_pin_released=1
fi

release_retry=0
if run_b >"$RESULT_ROOT/evidence/b_after_ack.txt" 2>&1 && verify_b; then
  release_retry=1
fi
cp "$commit_file" "$RESULT_ROOT/evidence/b_after_ack_commit.json" 2>/dev/null || true
python3 "$JOURNAL_LIB" inventory --store "$STORE_ROOT" >"$RESULT_ROOT/evidence/final_inventory.json"
python3 "$JOURNAL_LIB" health --store "$STORE_ROOT" >"$RESULT_ROOT/evidence/final_health.txt"

a_original_after_release=0
if python3 - "$A_TRUST_FILE" <<'PY'
import json
import os
import pathlib
import sys

trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
for name in ("producer", "shipper"):
    item = trust[name]
    pid = item["pid"]
    assert pathlib.Path(f"/proc/{pid}").exists()
    assert pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == item["start_ticks"]
    assert os.getpgid(pid) == item["process_group"]
print("A_ORIGINAL_AFTER_RELEASE=1 producer=1 shipper=1")
PY
then
  a_original_after_release=1
fi

bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
started=0
trap - EXIT

if [ "$b_alone$b_capacity_blocked$capacity_measured$peer$alternatives_excluded$exact_pin_released$release_retry$a_original_after_release" = 11111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 CAPACITY_MEASURED=1 B_WITH_A_CAPACITY_FAILED=1 NO_B_MARKER=1 PROVENANCE_EXTENT_IDENTITIES_AND_DIGESTS_STABLE=1 ALTERNATIVES_EXCLUDED=1 EXACT_REPLICA_PIN_ACKNOWLEDGED=1 RELEASE_RETRY_OK=1 A_ORIGINAL_AFTER_RELEASE=1 RESOURCE=append_log REASON=retention_pinned_log_capacity"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$peer B_ALONE_OK=$b_alone CAPACITY_MEASURED=$capacity_measured B_WITH_A_CAPACITY_FAILED=$b_capacity_blocked PROVENANCE_EXTENT_IDENTITIES_AND_DIGESTS_STABLE=$peer ALTERNATIVES_EXCLUDED=$alternatives_excluded EXACT_REPLICA_PIN_ACKNOWLEDGED=$exact_pin_released RELEASE_RETRY_OK=$release_retry A_ORIGINAL_AFTER_RELEASE=$a_original_after_release RESOURCE=append_log joint_rc=$joint_rc"
  exit 1
fi
