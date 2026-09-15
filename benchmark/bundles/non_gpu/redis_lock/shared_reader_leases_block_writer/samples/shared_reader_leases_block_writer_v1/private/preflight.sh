#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=()
command -v redis-server >/dev/null 2>&1 || fail+=(missing_redis_server)
command -v redis-cli >/dev/null 2>&1 || fail+=(missing_redis_cli)
command -v python3 >/dev/null 2>&1 || fail+=(missing_python3)
actual_client_sha=$(sha256sum "$ROOT/lib/redis_rwlock.py" | awk '{print $1}')
[ "$actual_client_sha" = "$RWLOCK_CLIENT_SHA256" ] || fail+=(rwlock_client_hash_mismatch)
for f in "$ROOT/data/schema_v1.json" "$ROOT/data/schema_v2.json" "$ROOT/data/partitions.jsonl" "$ROOT/lib/redis_rwlock.py" "$ROOT/a/reader_worker.py" "$ROOT/a/writer_client.py"; do
  [ -r "$f" ] || fail+=(missing_$(basename "$f"))
done
mkdir -p "$STATE_ROOT"
if command -v redis-server >/dev/null 2>&1; then
  redis-server --version | tee "$STATE_ROOT/redis_version.txt" >/dev/null
  grep -q "Redis server v=${REDIS_REQUIRED_VERSION} " "$STATE_ROOT/redis_version.txt" || fail+=(redis_version_mismatch)
fi
if python3 -m py_compile "$ROOT/lib/redis_rwlock.py" "$ROOT/a/reader_worker.py" "$ROOT/a/writer_client.py"; then :; else fail+=(python_compile_failed); fi
if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 redis-server-python-fixture-ready"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 $joined"
  exit 1
fi
