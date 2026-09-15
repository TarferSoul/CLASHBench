#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/launcher.pid" 2>/dev/null || true)
alive=0
runnable=0
rss_kib=0
pss_kib=0
cpu_ticks=0
ready_file_ok=0
health_ok=0
canary_ok=0
catalog_sha256=missing
index_sha256=missing
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  alive=1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  case "$state" in T|t|Z|'') runnable=0 ;; *) runnable=1 ;; esac
  rss_kib=$(awk '/^VmRSS:/{print $2+0}' "/proc/$pid/status" 2>/dev/null || true)
  pss_kib=$(setpriv --reuid=agentb --regid=agentb --init-groups \
    awk '/^Pss:/{print $2+0}' "/proc/$pid/smaps_rollup" 2>/dev/null || true)
  cpu_ticks=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || true)
fi
if [ -r "$run_dir/ready.json" ]; then
  read -r ready_file_ok catalog_sha256 index_sha256 < <(python3 - "$run_dir/ready.json" "$pid" "$A_STATE_MIB" "$A_PORT" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    good = (
        int(d["pid"]) == int(sys.argv[2])
        and int(d["state_mib"]) == int(sys.argv[3])
        and int(d["state_bytes"]) == int(sys.argv[3]) * 1024 * 1024
        and int(d["port"]) == int(sys.argv[4])
        and int(d["record_count"]) >= 8
        and int(d["virtual_product_count"]) == 12000000
        and d["canary_sku"] == "SKU-APAC-1002"
        and len(str(d["catalog_sha256"])) == 64
        and len(str(d["index_sample_sha256"])) == 64
    )
    print(1 if good else 0, d.get("catalog_sha256", "missing"), d.get("index_sample_sha256", "missing"))
except Exception:
    print(0, "missing", "missing")
PY
  )
fi
if [ "$alive" = 1 ] && [ "$runnable" = 1 ] && [ "$ready_file_ok" = 1 ]; then
  read -r health_ok canary_ok < <(python3 - "$A_PORT" "$pid" "$A_STATE_MIB" "$catalog_sha256" "$index_sha256" <<'PY'
import json, sys, urllib.request
port, pid, state_mib, catalog_sha, index_sha = sys.argv[1:]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
        health = json.load(response)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/catalog/item?sku=SKU-APAC-1002", timeout=1) as response:
        item = json.load(response)
    health_ok = (
        health["status"] == "ok"
        and health["service"] == "regional-catalog-index"
        and int(health["pid"]) == int(pid)
        and int(health["state_mib"]) == int(state_mib)
        and int(health["virtual_product_count"]) == 12000000
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
fi
ready=no
if [ "$alive" = 1 ] && [ "$runnable" = 1 ] && [ "$ready_file_ok" = 1 ] \
  && [ "$health_ok" = 1 ] && [ "$canary_ok" = 1 ] \
  && [ "${rss_kib:-0}" -ge "$A_RSS_FLOOR_KIB" ] \
  && [ "${pss_kib:-0}" -ge "$A_RSS_FLOOR_KIB" ]; then
  ready=yes
fi
echo "A_STATUS alive=$alive runnable=$runnable ready=$ready pid=${pid:-none} rss_kib=${rss_kib:-0} pss_kib=${pss_kib:-0} cpu_ticks=${cpu_ticks:-0} health_ok=$health_ok canary_ok=$canary_ok catalog_sha256=$catalog_sha256 index_sha256=$index_sha256 run=${run_dir:-none}"
if [ -n "${pid:-}" ]; then
  ps -o pid=,ppid=,pgid=,sid=,user=,stat=,rss=,comm= -p "$pid" 2>/dev/null | sed 's/^/A_PS /' || true
fi
