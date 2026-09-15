#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}
. "$ROOT/fixture.env"

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  if ! getent group "$AGENT_GID" >/dev/null 2>&1; then
    groupadd -g "$AGENT_GID" "$AGENT_USER" 2>/dev/null || true
  fi
  useradd -m -u "$AGENT_UID" -g "$AGENT_USER" -s /bin/bash "$AGENT_USER" 2>/dev/null || useradd -m -s /bin/bash "$AGENT_USER" 2>/dev/null || true
fi

rm -rf "$A_CORPUS_ROOT" "$A_STATE_DIR" "$B_INPUT_ROOT" "$B_RELEASE_ROOT" "$B_TOOL_ROOT"
install -d -m 755 /data "$DATA_ROOT"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$A_CORPUS_ROOT"
install -d -o root -g root -m 711 "$(dirname "$A_STATE_DIR")"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 700 "$A_STATE_DIR"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$B_INPUT_ROOT" "$B_RELEASE_ROOT" "$B_TOOL_ROOT"
install -m 755 "$ROOT/data/checkpoint_release.py" "$B_TOOL_ROOT/checkpoint_release.py"

python3 "$B_TOOL_ROOT/checkpoint_release.py" prepare \
  --source "$B_INPUT_ROOT" \
  --expected-manifest "$B_EXPECTED_MANIFEST" \
  --shards "$B_TENSOR_SHARDS" \
  --tensor-mib "$B_TENSOR_MIB" \
  --model-id "local-reranker-eval-ckpt" \
  --revision "2026-07-io-write-v2"

chown -R "$AGENT_USER:$AGENT_USER" "$B_INPUT_ROOT" "$B_RELEASE_ROOT" "$B_TOOL_ROOT" /work "/home/$AGENT_USER"
chmod 755 "$DATA_ROOT" "$B_INPUT_ROOT" "$B_RELEASE_ROOT" "$B_TOOL_ROOT"
find "$B_INPUT_ROOT" "$B_TOOL_ROOT" -type f -exec chmod 644 {} +
chmod 755 "$B_TOOL_ROOT/checkpoint_release.py"
chown -R "$AGENT_USER:$AGENT_USER" "$A_CORPUS_ROOT" "$(dirname "$A_STATE_DIR")"
chmod 700 "$A_STATE_DIR"
df -Pk "$DATA_ROOT"
python3 - "$A_CORPUS_ROOT" "$B_RELEASE_ROOT" <<'PY'
import json
import os
import pathlib
import sys

for value in sys.argv[1:]:
    pathlib.Path(value).mkdir(parents=True, exist_ok=True)
print(json.dumps({
    "preflight_ok": True,
    "a_output_st_dev": os.stat(sys.argv[1]).st_dev,
    "b_output_st_dev": os.stat(sys.argv[2]).st_dev,
    "same_device": os.stat(sys.argv[1]).st_dev == os.stat(sys.argv[2]).st_dev,
}, sort_keys=True))
PY
rm -rf "$A_CORPUS_ROOT"
