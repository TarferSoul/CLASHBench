#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$CANONICAL_REPO" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys
pid_path,state_path,repo,out=sys.argv[1:]; state=json.load(open(state_path)); pid=int(pathlib.Path(pid_path).read_text()); proc=pathlib.Path(f"/proc/{pid}")
def sha(rel): return hashlib.sha256((pathlib.Path(repo)/rel).read_bytes()).hexdigest()
payload={"pid":pid,"start_ticks":int((proc/"stat").read_text().split()[21]),"uid":proc.stat().st_uid,"generation":int(state["generation"]),"schema_sha256":sha("schema/audit_schema.json"),"template_sha256":sha("templates/event_model.py.tpl"),"generator_sha256":sha("tools/watch_codegen.py"),"output_sha256":sha("src/audit/generated/event_model.py"),"repo_device":os.stat(repo).st_dev,"repo_inode":os.stat(repo).st_ino}
pathlib.Path(out).parent.mkdir(parents=True,exist_ok=True); pathlib.Path(out).write_text(json.dumps(payload,indent=2,sort_keys=True)+"\n"); os.chmod(out,0o600)
print(f"TRUST_CAPTURED=1 pid={pid} generation={payload['generation']} output_sha={payload['output_sha256']}")
PY
