#!/usr/bin/env bash
set -Eeuo pipefail

shards=
output=
concurrency=${CHECKPOINT_READ_CONCURRENCY:-${B_READ_WORKERS:-4}}
block_bytes=${DIRECT_BLOCK_BYTES:-4194304}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --shards) shards=${2:?}; shift 2 ;;
    --output) output=${2:?}; shift 2 ;;
    --concurrency) concurrency=${2:?}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$shards" ] && [ -d "$shards" ] || { echo "missing shard directory" >&2; exit 2; }
[ -n "$output" ] || { echo "missing output manifest" >&2; exit 2; }
[[ "$concurrency" =~ ^[0-9]+$ ]] && [ "$concurrency" -gt 0 ] || { echo "bad concurrency" >&2; exit 2; }

export LC_ALL=C
runtime=/tmp/checkpoint-direct-read.$$
rm -rf "$runtime"
mkdir -p "$runtime"
trap 'rm -rf "$runtime"' EXIT

sentinel_ok() {
  local input=$1 prefix=$2 offset=${3:-0}
  local text
  if [ "$offset" -eq 0 ]; then
    text=$(dd if="$input" bs=128 count=1 status=none 2>/dev/null | tr -d '\000' | head -c 128)
  else
    text=$(dd if="$input" bs=1 skip="$offset" count=128 status=none 2>/dev/null | tr -d '\000' | head -c 128)
  fi
  case "$text" in
    "$prefix"*) return 0 ;;
    *) return 1 ;;
  esac
}

read_one() {
  local input=$1 index=$2
  local name size footer_offset receipt direct_bytes start_ns end_ns rc=0
  name=$(basename "$input")
  size=$(stat -c '%s' "$input")
  footer_offset=$((size - 4096))
  start_ns=$(date +%s%N)
  dd if="$input" of=/dev/null iflag=direct,fullblock bs="$block_bytes" >"$runtime/$index.dd.out" 2>"$runtime/$index.dd.err" || rc=$?
  end_ns=$(date +%s%N)
  direct_bytes=$(awk '/ bytes .* copied/ {print $1; exit}' "$runtime/$index.dd.err")
  direct_bytes=${direct_bytes:-0}
  header_ok=0
  footer_ok=0
  sentinel_ok "$input" CHECKPOINT_SHARD_HEADER_ 0 && header_ok=1
  sentinel_ok "$input" CHECKPOINT_SHARD_FOOTER_ "$footer_offset" && footer_ok=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$size" "$direct_bytes" "$header_ok" "$footer_ok" "$start_ns" "$end_ns" "$rc" \
    >"$runtime/result.$index"
}

wait_batch() {
  local child failed=0
  for child in "$@"; do
    if ! wait "$child"; then
      failed=1
    fi
  done
  return "$failed"
}

start_ns=$(date +%s%N)
pids=()
index=0
while IFS= read -r input; do
  read_one "$input" "$index" &
  pids+=("$!")
  index=$((index + 1))
  if [ "${#pids[@]}" -ge "$concurrency" ]; then
    wait_batch "${pids[@]}"
    pids=()
  fi
done < <(find "$shards" -maxdepth 1 -type f -name '*.bin' | sort)
if [ "${#pids[@]}" -gt 0 ]; then
  wait_batch "${pids[@]}"
fi
end_ns=$(date +%s%N)

mkdir -p "$(dirname "$output")"
python3 - "$runtime" "$output" "$start_ns" "$end_ns" "${CHECKPOINT_AUDIT_METRICS:-}" <<'PY'
import json
import pathlib
import sys

runtime = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
start_ns = int(sys.argv[3])
end_ns = int(sys.argv[4])
metrics_path = pathlib.Path(sys.argv[5]) if sys.argv[5] else None

shards = []
ok = True
for path in sorted(runtime.glob("result.*"), key=lambda p: int(p.name.split(".")[-1])):
    name, size, direct, header_ok, footer_ok, begin, end, rc = path.read_text().strip().split("\t")
    size_i = int(size)
    direct_i = int(direct)
    item_ok = int(rc) == 0 and direct_i == size_i and header_ok == "1" and footer_ok == "1"
    ok = ok and item_ok
    shards.append({
        "name": name,
        "bytes": size_i,
        "direct_read_bytes": direct_i,
        "header_ok": header_ok == "1",
        "footer_ok": footer_ok == "1",
        "elapsed_ns": int(end) - int(begin),
        "ok": item_ok,
    })

payload = {
    "status": "complete" if ok else "incomplete",
    "shard_count": len(shards),
    "total_bytes": sum(item["bytes"] for item in shards),
    "direct_read_bytes": sum(item["direct_read_bytes"] for item in shards),
    "elapsed_ns": end_ns - start_ns,
    "shards": shards,
}
tmp = out.with_name(out.name + ".tmp")
tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
tmp.replace(out)

if metrics_path:
    metrics_path.write_text(
        "\n".join([
            f"elapsed_ns={payload['elapsed_ns']}",
            f"shard_count={payload['shard_count']}",
            f"total_bytes={payload['total_bytes']}",
            f"physical_read_bytes={payload['direct_read_bytes']}",
            f"status={payload['status']}",
            "",
        ])
    )
print(
    f"CHECKPOINT_AUDIT status={payload['status']} shards={payload['shard_count']} "
    f"bytes={payload['total_bytes']} direct_read_bytes={payload['direct_read_bytes']} "
    f"elapsed_ns={payload['elapsed_ns']}"
)
raise SystemExit(0 if ok else 1)
PY
