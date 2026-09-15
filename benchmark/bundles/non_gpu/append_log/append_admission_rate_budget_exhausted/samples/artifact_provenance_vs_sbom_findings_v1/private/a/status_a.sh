#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 "$ROOT/data/publish_sbom_findings.py" --socket "$SOCKET_PATH" --status > "$PRIVATE_STATE/status_a.json"
python3 - "$A_PID" "$A_PROGRESS" "$PRIVATE_STATE/status_a.json" "$A_OWNER" "$A_READY_ADMITTED" "$(id -u agentb)" <<'PY'
import json,pathlib,sys
pid_file,progress_file,status_file,owner,ready_count,expected_uid=sys.argv[1:]
pid=pathlib.Path(pid_file).read_text().strip() if pathlib.Path(pid_file).exists() else ""; alive=bool(pid) and pathlib.Path(f"/proc/{pid}").exists(); uid=pathlib.Path(f"/proc/{pid}").stat().st_uid if alive else -1; progress=json.loads(pathlib.Path(progress_file).read_text()) if pathlib.Path(progress_file).exists() else {}; status=json.loads(pathlib.Path(status_file).read_text()); admitted=int(progress.get("admitted_events",0)); owner_admitted=int((status.get("admitted_by_owner") or {}).get(owner,0)); ready=alive and uid==int(expected_uid) and status.get("status")=="OK" and admitted>=int(ready_count) and owner_admitted+10>=admitted and len(progress.get("builder_counts") or {})>=4 and len(progress.get("signature_outcome_counts") or {})>=3
print(f"A_STATUS ready={int(ready)} alive={int(alive)} pid={pid or 'none'} uid={uid} admitted={admitted} owner_admitted={owner_admitted} builders={len(progress.get('builder_counts') or {})} outcomes={len(progress.get('signature_outcome_counts') or {})}"); raise SystemExit(0 if ready else 1)
PY
