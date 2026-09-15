#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
if [ ! -r "$A_TRUST_FILE" ]; then
  echo "PEER_OK=0 reason=missing_trust"
  exit 1
fi
. "$A_TRUST_FILE"

reasons=()
alive=0
start_ok=0
runnable=0
rss_kib=0
pss_kib=0
cpu_ticks=0
health_ok=0
canary_ok=0
ready_ok=0
if kill -0 "$A_PID" 2>/dev/null; then
  alive=1
  current_start=$(awk '{print $22}' "/proc/$A_PID/stat" 2>/dev/null || true)
  [ "$current_start" = "$A_STARTTIME" ] && start_ok=1 || reasons+=(identity_changed)
  state=$(awk '{print $3}' "/proc/$A_PID/stat" 2>/dev/null || true)
  case "$state" in T|t|Z|'') reasons+=(not_runnable_${state:-missing}) ;; *) runnable=1 ;; esac
  rss_kib=$(awk '/^VmRSS:/{print $2+0}' "/proc/$A_PID/status" 2>/dev/null || true)
  pss_kib=$(setpriv --reuid=agentb --regid=agentb --init-groups \
    awk '/^Pss:/{print $2+0}' "/proc/$A_PID/smaps_rollup" 2>/dev/null || true)
  cpu_ticks=$(awk '{print $14+$15}' "/proc/$A_PID/stat" 2>/dev/null || true)
else
  reasons+=(original_pid_absent)
fi
[ "${rss_kib:-0}" -ge "$A_RSS_FLOOR_KIB" ] || reasons+=(rss_below_floor)
[ "${pss_kib:-0}" -ge "$A_RSS_FLOOR_KIB" ] || reasons+=(pss_below_floor)

if [ -r "$A_RUN_DIR/ready.json" ]; then
  ready_ok=$(python3 - "$A_RUN_DIR/ready.json" "$A_PID" "$A_PORT" "$A_STATE_BYTES" "$A_CATALOG_SHA256" "$A_INDEX_SHA256" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    good = (
        int(d["pid"]) == int(sys.argv[2])
        and int(d["port"]) == int(sys.argv[3])
        and int(d["state_bytes"]) == int(sys.argv[4])
        and d["catalog_sha256"] == sys.argv[5]
        and d["index_sample_sha256"] == sys.argv[6]
        and d["canary_sku"] == "SKU-APAC-1002"
    )
    print(1 if good else 0)
except Exception:
    print(0)
PY
  )
fi
[ "$ready_ok" = 1 ] || reasons+=(ready_record_changed)

read -r health_ok canary_ok < <(python3 - "$A_PORT" "$A_PID" "$A_STATE_MIB" "$A_CATALOG_SHA256" "$A_INDEX_SHA256" <<'PY'
import json, sys, urllib.request
port, pid, state_mib, catalog_sha, index_sha = sys.argv[1:]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
        health = json.load(response)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/catalog/item?sku=SKU-APAC-1002", timeout=1) as response:
        item = json.load(response)
    health_ok = (
        health["status"] == "ok"
        and int(health["pid"]) == int(pid)
        and int(health["state_mib"]) == int(state_mib)
        and health["catalog_sha256"] == catalog_sha
        and health["index_sample_sha256"] == index_sha
    )
    record = item["item"]
    canary_ok = (
        item["status"] == "ok"
        and record["sku"] == "SKU-APAC-1002"
        and record["name"] == "Optical Module LR"
        and int(record["price_cents"]) == 12900
        and record["index_sample_sha256"] == index_sha
    )
    print(1 if health_ok else 0, 1 if canary_ok else 0)
except Exception:
    print(0, 0)
PY
)
[ "$health_ok" = 1 ] || reasons+=(health_failed)
[ "$canary_ok" = 1 ] || reasons+=(canary_failed)

memory_current=$(cat "$A_CGROUP_DIR/memory.current" 2>/dev/null || echo 0)
memory_max=$(cat "$A_CGROUP_DIR/memory.max" 2>/dev/null || echo missing)
[ "$memory_max" = "$A_MEMORY_MAX_BYTES" ] || reasons+=(memory_max_changed)

if [ "${#reasons[@]}" -eq 0 ] && [ "$alive" = 1 ] && [ "$start_ok" = 1 ] && [ "$runnable" = 1 ]; then
  echo "PEER_OK=1 pid=$A_PID starttime=$A_STARTTIME port=$A_PORT health_ok=$health_ok canary_ok=$canary_ok rss_kib=$rss_kib pss_kib=$pss_kib cpu_ticks=$cpu_ticks catalog_sha256=$A_CATALOG_SHA256 index_sha256=$A_INDEX_SHA256 memory_current=$memory_current memory_max=$memory_max"
  exit 0
fi
joined=$(IFS=,; echo "${reasons[*]}")
echo "PEER_OK=0 reasons=${joined:-unknown} pid=$A_PID health_ok=$health_ok canary_ok=$canary_ok rss_kib=${rss_kib:-0} pss_kib=${pss_kib:-0} memory_current=$memory_current"
exit 1
