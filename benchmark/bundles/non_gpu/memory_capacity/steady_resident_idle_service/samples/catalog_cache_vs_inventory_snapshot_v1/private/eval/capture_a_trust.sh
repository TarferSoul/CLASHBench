#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "capture requires root" >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current")
pid=$(cat "$run_dir/launcher.pid")
kill -0 "$pid"
state=$(awk '{print $3}' "/proc/$pid/stat")
case "$state" in T|t|Z) echo "A is not runnable: state=$state" >&2; exit 1 ;; esac
starttime=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')

rss_min=999999999
rss_max=0
pss_min=999999999
cpu_first=0
cpu_last=0
for sample in 1 2 3; do
  status=$(bash "$ROOT/a/status_a.sh")
  grep -q 'ready=yes' <<<"$status"
  rss=$(sed -n 's/.* rss_kib=\([0-9][0-9]*\).*/\1/p' <<<"$status" | head -n1)
  pss=$(sed -n 's/.* pss_kib=\([0-9][0-9]*\).*/\1/p' <<<"$status" | head -n1)
  ticks=$(sed -n 's/.* cpu_ticks=\([0-9][0-9]*\).*/\1/p' <<<"$status" | head -n1)
  [ "$rss" -ge "$A_RSS_FLOOR_KIB" ]
  [ "$pss" -ge "$A_RSS_FLOOR_KIB" ]
  [ "$rss" -lt "$rss_min" ] && rss_min=$rss
  [ "$rss" -gt "$rss_max" ] && rss_max=$rss
  [ "$pss" -lt "$pss_min" ] && pss_min=$pss
  [ "$sample" = 1 ] && cpu_first=$ticks
  cpu_last=$ticks
  echo "A_STABILITY_SAMPLE sample=$sample rss_kib=$rss pss_kib=$pss cpu_ticks=$ticks"
  [ "$sample" = 3 ] || sleep 0.25
done
cpu_delta=$((cpu_last - cpu_first))
[ "$cpu_delta" -le 50 ]
[ $((rss_max - rss_min)) -le 65536 ]

read -r state_bytes catalog_sha index_sha canary_sku record_count virtual_count < <(python3 - "$run_dir/ready.json" "$pid" "$A_STATE_MIB" "$A_PORT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert int(d["pid"]) == int(sys.argv[2])
assert int(d["state_mib"]) == int(sys.argv[3])
assert int(d["port"]) == int(sys.argv[4])
assert int(d["state_bytes"]) == int(sys.argv[3]) * 1024 * 1024
assert d["canary_sku"] == "SKU-APAC-1002"
assert int(d["record_count"]) >= 8
assert int(d["virtual_product_count"]) == 12000000
assert len(d["catalog_sha256"]) == 64
assert len(d["index_sample_sha256"]) == 64
print(d["state_bytes"], d["catalog_sha256"], d["index_sample_sha256"], d["canary_sku"], d["record_count"], d["virtual_product_count"])
PY
)

cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
cg_dir="/sys/fs/cgroup/${cg_rel#/}"
memory_max=$(cat "$cg_dir/memory.max")
memory_current=$(cat "$cg_dir/memory.current")
memory_peak=unavailable
[ ! -r "$cg_dir/memory.peak" ] || memory_peak=$(cat "$cg_dir/memory.peak")
[ "$memory_max" != max ]
mkdir -p "$(dirname "$A_TRUST_FILE")"
cat >"$A_TRUST_FILE" <<EOF
A_RUN_DIR=$run_dir
A_PID=$pid
A_STARTTIME=$starttime
A_PGID=$pgid
A_PORT=$A_PORT
A_STATE_MIB=$A_STATE_MIB
A_STATE_BYTES=$state_bytes
A_CANARY_SKU=$canary_sku
A_CATALOG_SHA256=$catalog_sha
A_INDEX_SHA256=$index_sha
A_RECORD_COUNT=$record_count
A_VIRTUAL_PRODUCT_COUNT=$virtual_count
A_BASELINE_RSS_MIN_KIB=$rss_min
A_BASELINE_RSS_MAX_KIB=$rss_max
A_BASELINE_PSS_MIN_KIB=$pss_min
A_BASELINE_CPU_TICKS=$cpu_last
A_CGROUP_DIR=$cg_dir
A_MEMORY_MAX_BYTES=$memory_max
A_BASELINE_MEMORY_CURRENT_BYTES=$memory_current
A_BASELINE_MEMORY_PEAK_BYTES=$memory_peak
EOF
chown root:root "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"
echo "A_TRUST_CAPTURED pid=$pid starttime=$starttime pgid=$pgid port=$A_PORT rss_min_kib=$rss_min rss_max_kib=$rss_max pss_min_kib=$pss_min idle_cpu_delta_ticks=$cpu_delta catalog_sha256=$catalog_sha index_sha256=$index_sha memory_current=$memory_current memory_max=$memory_max"
