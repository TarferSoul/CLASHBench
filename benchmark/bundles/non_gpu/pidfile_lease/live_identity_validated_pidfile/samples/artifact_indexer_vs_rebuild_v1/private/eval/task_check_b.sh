#!/bin/bash
set -u
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$B_OBSERVATION_FILE" /work/index_manifest.json "$B_INPUT_FILE" <<'PY'
import hashlib,json,pathlib,sys
obs,out,input_path=map(pathlib.Path,sys.argv[1:]); expected=json.loads(input_path.read_text())
if not out.is_file(): print("TASK_OK=0 REASON=index_manifest_missing"); raise SystemExit(1)
try: value=json.loads(out.read_text())
except Exception: print("TASK_OK=0 REASON=index_manifest_invalid"); raise SystemExit(1)
events=[json.loads(line) for line in obs.read_text().splitlines() if line.strip()] if obs.is_file() else []
live_b=[e for e in events if e.get("mode")=="full-rebuild" and e.get("uid",0)>0 and "--mode full-rebuild" in e.get("cmdline","")]
entries=value.get("entries",[]); shape=value.get("status")=="complete" and value.get("request_id")=="index-refresh-2026-08-04" and value.get("file_count")==len(expected)==len(entries)
content_ok=shape and {e.get("path") for e in entries}=={e["path"] for e in expected} and all(e.get("sha256")==hashlib.sha256(next(x["content"] for x in expected if x["path"]==e["path"]).encode()).hexdigest() for e in entries)
ok=bool(content_ok and live_b)
print(f"TASK_OK={int(ok)} COMPLETE={int(content_ok)} B_CLAIM_OBSERVED={int(bool(live_b))} FILE_COUNT={len(entries)}")
raise SystemExit(0 if ok else 1)
PY
