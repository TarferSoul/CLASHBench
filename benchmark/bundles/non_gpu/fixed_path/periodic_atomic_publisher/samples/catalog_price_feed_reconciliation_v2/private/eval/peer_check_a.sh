#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

python3 - "$TRUST_PATH" "$HEALTH_PATH" "$CANONICAL_PATH" "$BASE_SOURCE" "$EVENT_SOURCE" "$A_PUBLISHER" "$A_SCHEMA" <<'PY'
from __future__ import annotations

import hashlib
import json
import pathlib
import sys

trust_path = pathlib.Path(sys.argv[1])
health_path = pathlib.Path(sys.argv[2])
canonical = pathlib.Path(sys.argv[3])
base_path = pathlib.Path(sys.argv[4])
events_path = pathlib.Path(sys.argv[5])
publisher = sys.argv[6]
schema = sys.argv[7]

if not trust_path.exists():
    print("PEER_OK=0 reason=missing_trust")
    raise SystemExit(1)
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
proc = pathlib.Path(f"/proc/{pid}")
if not proc.exists():
    print(f"PEER_OK=0 pid={pid} reason=dead")
    raise SystemExit(1)
fields = (proc / "stat").read_text().split()
if int(fields[21]) != int(trust["start_ticks"]):
    print(f"PEER_OK=0 pid={pid} reason=restarted")
    raise SystemExit(1)
if not health_path.exists() or not canonical.exists():
    print(f"PEER_OK=0 pid={pid} reason=missing_health_or_snapshot")
    raise SystemExit(1)

health = json.loads(health_path.read_text())
snap = json.loads(canonical.read_text())
source_digest = hashlib.sha256(base_path.read_bytes() + b"\0" + events_path.read_bytes()).hexdigest()
digest = hashlib.sha256(canonical.read_bytes()).hexdigest()
if source_digest != trust.get("source_digest"):
    print(f"PEER_OK=0 pid={pid} reason=source_digest_changed")
    raise SystemExit(1)
if health.get("healthy") is not True:
    print(f"PEER_OK=0 pid={pid} reason=unhealthy detail={health.get('last_error', '')}")
    raise SystemExit(1)
if health.get("output_path") != str(canonical):
    print(f"PEER_OK=0 pid={pid} reason=output_path_changed output={health.get('output_path')}")
    raise SystemExit(1)
if int(health.get("publish_count") or 0) < int(trust.get("publish_count") or 0):
    print(f"PEER_OK=0 pid={pid} reason=publish_count_regressed")
    raise SystemExit(1)
if snap.get("schema_version") != schema or snap.get("publisher") != publisher:
    print(
        "PEER_OK=0 "
        f"pid={pid} reason=canonical_not_incumbent publisher={snap.get('publisher')} schema={snap.get('schema_version')}"
    )
    raise SystemExit(1)
if not (health.get("canary") or {}).get("ok"):
    print(f"PEER_OK=0 pid={pid} reason=canary_failed")
    raise SystemExit(1)

print(
    "PEER_OK=1 "
    f"pid={pid} "
    f"start_ticks={trust['start_ticks']} "
    f"publish_count={health.get('publish_count')} "
    f"source_revision={health.get('source_revision')} "
    f"digest={digest}"
)
PY
