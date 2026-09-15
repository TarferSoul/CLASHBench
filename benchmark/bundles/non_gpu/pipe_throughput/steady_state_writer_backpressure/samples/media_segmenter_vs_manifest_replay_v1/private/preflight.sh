#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
for command in bash python3 setpriv runuser getconf; do command -v "$command" >/dev/null; done
test -x "$CONSUMER_BIN"
test -x "$A_BIN"
test "$FRAME_BYTES" -le "$(getconf PIPE_BUF /tmp)"
python3 - "$INPUT_SOURCE" "$FRAME_BYTES" "$B_RECORD_COUNT" <<'PY'
import hashlib, json, pathlib, sys
records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert len(records) == int(sys.argv[3])
assert len({r['segment_id'] for r in records}) == len(records)
for r in records:
    payload = str(r['payload'])
    raw = json.dumps({'producer':'release-manifest','record_id':'b-test-'+r['segment_id'],'payload':payload,'payload_sha256':hashlib.sha256(payload.encode()).hexdigest()}, separators=(',', ':'), sort_keys=True).encode()+b'\n'
    assert len(raw) <= int(sys.argv[2])
print(f"PREFLIGHT_OK=1 records={len(records)} frame_bytes={sys.argv[2]}")
PY
