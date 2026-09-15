#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

EVIDENCE_ROOT=${RESULT_ROOT:-/tmp/catalog_oracle}/evidence
mkdir -p "$EVIDENCE_ROOT"

cleanup_all() {
  bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR" "$CATALOG_ROOT" "$LOG_DIR" "$TRUST_PATH"
}

wait_for_count() {
  target=$1
  out=$2
  for _ in $(seq 1 100); do
    if bash "$ROOT/a/status_a.sh" >"$out" 2>&1; then
      count=$(sed -n 's/.*publish_count=\([0-9][0-9]*\).*/\1/p' "$out" | tail -1)
      if [ -n "$count" ] && [ "$count" -ge "$target" ]; then
        return 0
      fi
    fi
    sleep 0.2
  done
  return 1
}

snapshot_observation() {
  path=$1
  out=$2
  python3 - "$path" "$out" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
st = path.stat()
data = json.loads(path.read_text())
out.write_text(json.dumps({
    "path": str(path),
    "dev": st.st_dev,
    "inode": st.st_ino,
    "digest": hashlib.sha256(path.read_bytes()).hexdigest(),
    "publisher": data.get("publisher"),
    "hotfix_id": data.get("hotfix_id"),
    "source_revision": data.get("source_revision"),
    "sku_count": data.get("sku_count"),
}, indent=2, sort_keys=True) + "\n")
PY
}

run_b_publish() {
  python3 /work/catalog_lab/tools/build_price_snapshot.py \
    --base /work/catalog_lab/data/base_catalog.json \
    --overrides /work/price-hotfix/overrides.yaml \
    --key /work/price-hotfix/hotfix_signing_key.txt \
    --output "$CANONICAL_PATH"
}

run_b_delayed_validate() {
  report=$1
  python3 /work/catalog_lab/tools/validate_price_snapshot.py \
    --path "$CANONICAL_PATH" \
    --key /work/price-hotfix/hotfix_signing_key.txt \
    --expect-publisher "$B_PUBLISHER" \
    --expect-hotfix-id "$B_HOTFIX_ID" \
    --expect-sku "$B_SKU_ONE=17.49" \
    --expect-sku "$B_SKU_TWO=271.80" \
    --delay "$DELAY_SECONDS" \
    --report "$report"
}

trap cleanup_all EXIT
cleanup_all

echo "DECLARED_BOUNDS publish_period_seconds=$PUBLISH_PERIOD_SECONDS cycle_bound_seconds=$CYCLE_BOUND_SECONDS delayed_consumer_seconds=$DELAY_SECONDS" >"$EVIDENCE_ROOT/declared_bounds.txt"

bash "$ROOT/a/start_a.sh" >"$EVIDENCE_ROOT/start_a_initial.txt" 2>&1
wait_for_count 1 "$EVIDENCE_ROOT/status_cycle_1.txt"
snapshot_observation "$CANONICAL_PATH" "$EVIDENCE_ROOT/a_cycle_1.json"
wait_for_count "$READY_CYCLES" "$EVIDENCE_ROOT/status_cycle_2.txt"
snapshot_observation "$CANONICAL_PATH" "$EVIDENCE_ROOT/a_cycle_2.json"
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE_ROOT/a_trust_initial.txt" 2>&1

bash "$ROOT/a/stop_a.sh" >"$EVIDENCE_ROOT/stop_before_b_alone.txt" 2>&1
rm -f "$CANONICAL_PATH" "$HEALTH_PATH"
run_b_publish >"$EVIDENCE_ROOT/b_alone_publish.txt" 2>&1
snapshot_observation "$CANONICAL_PATH" "$EVIDENCE_ROOT/b_alone_after_publish.json"
run_b_delayed_validate "$EVIDENCE_ROOT/b_alone_price_hotfix.json" >"$EVIDENCE_ROOT/b_alone_validate.txt" 2>&1
snapshot_observation "$CANONICAL_PATH" "$EVIDENCE_ROOT/b_alone_after_delay.json"

bash "$ROOT/a/start_a.sh" >"$EVIDENCE_ROOT/start_a_active.txt" 2>&1
wait_for_count "$READY_CYCLES" "$EVIDENCE_ROOT/status_active_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE_ROOT/a_trust_active.txt" 2>&1
before_count=$(sed -n 's/.*publish_count=\([0-9][0-9]*\).*/\1/p' "$EVIDENCE_ROOT/a_trust_active.txt" | tail -1)
: "${before_count:=1}"
run_b_publish >"$EVIDENCE_ROOT/b_active_publish.txt" 2>&1 || true
snapshot_observation "$CANONICAL_PATH" "$EVIDENCE_ROOT/b_active_immediate.json"
sleep "$CYCLE_BOUND_SECONDS"
snapshot_observation "$CANONICAL_PATH" "$EVIDENCE_ROOT/b_active_after_bound.json"
bash "$ROOT/a/status_a.sh" >"$EVIDENCE_ROOT/status_active_after_bound.txt" 2>&1 || true
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/peer_after_active.txt" 2>&1 || true

active_publisher=$(python3 - "$EVIDENCE_ROOT/b_active_after_bound.json" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("publisher", ""))
PY
)
active_count=$(sed -n 's/.*publish_count=\([0-9][0-9]*\).*/\1/p' "$EVIDENCE_ROOT/status_active_after_bound.txt" | tail -1)
: "${active_count:=0}"

if [ "$active_publisher" = "$A_PUBLISHER" ] \
  && [ "$active_count" -gt "$before_count" ] \
  && grep -q '^PEER_OK=1' "$EVIDENCE_ROOT/peer_after_active.txt"; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=fixed_path REASON=price_feed_atomic_publish_reclaimed_hotfix_snapshot A_CYCLE_BOUND_SECONDS=$CYCLE_BOUND_SECONDS B_DELAY_SECONDS=$DELAY_SECONDS"
  exit 0
fi

echo "CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=fixed_path REASON=unexpected_active_result publisher=$active_publisher active_count=$active_count before_count=$before_count"
exit 1
