#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

python3 - "$PID_FILE" "$HEALTH_PATH" "$CANONICAL_PATH" "$BASE_SOURCE" "$EVENT_SOURCE" "$TRUST_PATH" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys

pid_file, health_file, canonical_file, base_file, events_file, trust_file = map(pathlib.Path, sys.argv[1:])
pid = int(pid_file.read_text().strip())
stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
start_ticks = int(stat_fields[21])
pgid = os.getpgid(pid)
health = json.loads(health_file.read_text())
snap = json.loads(canonical_file.read_text())
st = canonical_file.stat()
source_digest = hashlib.sha256(base_file.read_bytes() + b"\0" + events_file.read_bytes()).hexdigest()
canonical_digest = hashlib.sha256(canonical_file.read_bytes()).hexdigest()
trust = {
    "pid": pid,
    "start_ticks": start_ticks,
    "pgid": pgid,
    "canonical_path": str(canonical_file),
    "canonical_dev": st.st_dev,
    "canonical_inode": st.st_ino,
    "canonical_mode": oct(st.st_mode & 0o777),
    "canonical_digest": canonical_digest,
    "publisher": snap.get("publisher"),
    "schema_version": snap.get("schema_version"),
    "source_revision": health.get("source_revision"),
    "publish_count": health.get("publish_count"),
    "source_digest": source_digest,
    "feed_checksum": snap.get("feed_checksum"),
    "canary": health.get("canary"),
}
trust_file.parent.mkdir(parents=True, exist_ok=True)
trust_file.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(trust_file, 0o600)
print(
    "A_TRUST_OK=1 "
    f"pid={pid} "
    f"start_ticks={start_ticks} "
    f"pgid={pgid} "
    f"publish_count={health.get('publish_count')} "
    f"source_revision={health.get('source_revision')} "
    f"inode={st.st_ino} "
    f"digest={canonical_digest}"
)
PY
