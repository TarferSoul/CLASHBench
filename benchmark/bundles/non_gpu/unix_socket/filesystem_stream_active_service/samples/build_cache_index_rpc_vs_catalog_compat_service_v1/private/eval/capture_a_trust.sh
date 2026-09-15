#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
: "${RESULT_ROOT:?set RESULT_ROOT}"

# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

[ -s "$PID_FILE" ] || { echo "A_TRUST_CAPTURED=0 reason=missing_pid_file"; exit 1; }
pid=$(cat "$PID_FILE")
kill -0 "$pid" 2>/dev/null || { echo "A_TRUST_CAPTURED=0 reason=pid_not_alive pid=$pid"; exit 1; }

mkdir -p "$(dirname "$TRUST_FILE")" "$RESULT_ROOT/evidence"
chmod 0700 "$(dirname "$TRUST_FILE")" "$RESULT_ROOT/evidence"

probe_digest="sha256:trust-capture-$(date +%s)-$$"
python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" commit \
  --socket "$SOCKET_PATH" \
  --digest "$probe_digest" \
  --builder trust-capture \
  --size 5120 \
  > "$RESULT_ROOT/evidence/a_trust_commit.json"

tmp=$(mktemp)
python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" snapshot --socket "$SOCKET_PATH" --pid "$pid" > "$tmp"
python3 - "$tmp" "$TRUST_FILE" "$SUPERVISOR_PID_FILE" "$RESTART_COUNT_FILE" <<'PY'
import json
import pathlib
import sys

src, dst, supervisor_path, restart_path = sys.argv[1:5]
data = json.load(open(src, encoding="utf-8"))
stats = data.get("stats") or {}
supervisor_pid = int(pathlib.Path(supervisor_path).read_text().strip())
restart_count = int(pathlib.Path(restart_path).read_text().strip())
data["supervisor_pid"] = supervisor_pid
data["restart_count"] = restart_count
required = [
    data.get("process_exists") is True,
    (data.get("path_stat") or {}).get("is_socket") is True,
    bool(data.get("kernel_inode")),
    bool(data.get("fd_matches")) or any(str(data.get("kernel_inode")) in line for line in (data.get("ss") or {}).get("lines", [])),
    stats.get("ok") is True,
    stats.get("service") == "build-cache-index",
    int(stats.get("request_count") or 0) >= 1,
    int(stats.get("commit_count") or 0) >= 1,
    supervisor_pid > 0,
    restart_count == 0,
]
if not all(required):
    print("A_TRUST_CAPTURED=0 reason=incomplete_snapshot")
    print(json.dumps(data, sort_keys=True))
    raise SystemExit(1)
path = pathlib.Path(dst)
tmp = path.with_suffix(".tmp")
tmp.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
path.chmod(0o600)
print(
    "A_TRUST_CAPTURED=1 pid={pid} start_time={start} kernel_inode={inode} request_count={req} commit_count={commits}".format(
        pid=data.get("pid"),
        start=data.get("start_time"),
        inode=data.get("kernel_inode"),
        req=stats.get("request_count"),
        commits=stats.get("commit_count"),
    )
)
PY
rm -f "$tmp"
