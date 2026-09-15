#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
set -a
. "$ROOT/fixture.env"
set +a
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
python3 "$ROOT/data/segment_append.py" init >/dev/null
cp "$ROOT/data/segment_append.py" "$SEGMENT_RUN/segment-sealer"
chmod 755 "$SEGMENT_RUN/segment-sealer"
chown -R agentb:agentb "$SEGMENT_STORE" "$SEGMENT_RUN"
chmod 755 "$SEGMENT_STORE" "$SEGMENT_RUN"
chmod 664 "$SEGMENT_STORE"/* "$SEGMENT_LOCK"
printf 'PREFLIGHT_OK=1 store=%s generation=%s\n' "$SEGMENT_STORE" "$SEGMENT_INITIAL_GENERATION"
