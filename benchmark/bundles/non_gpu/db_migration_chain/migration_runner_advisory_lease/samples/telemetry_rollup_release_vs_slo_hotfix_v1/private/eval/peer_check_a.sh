#!/usr/bin/env bash
set -euo pipefail
python3 - "$TRUST_PATH" <<'PY'
import json, os, pathlib, subprocess, sys
trust=json.load(open(sys.argv[1]))
db=os.environ["DB_NAME"]
def scalar(sql):
    p=subprocess.run(["psql","-X","-qAt","-d",db,"-c",sql],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()
def exact_alive(pid,start):
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]) == int(start)
    except Exception: return False
expected=[
 ("V20260804_101","sha256:telemetry-rollup-101"),
 ("V20260804_102","sha256:telemetry-tier-102"),
 ("V20260804_103","sha256:telemetry-tier-backfill-103"),
 ("V20260804_104","sha256:telemetry-tier-index-104"),
 ("V20260804_105","sha256:telemetry-validate-105"),
]
rows=[tuple(x.split("|",1)) for x in scalar("select version,checksum from schema_history where version between 'V20260804_101' and 'V20260804_105' order by installed_rank").splitlines() if x]
state=scalar("select status||'|'||client_pid||'|'||backend_pid||'|'||current_version||'|'||rows_validated from release_state where namespace='observability_catalog'")
parts=state.split("|") if state else []
client_alive=exact_alive(trust["client_pid"],trust["client_start_ticks"])
backend_alive=exact_alive(trust["backend_pid"],trust["backend_start_ticks"])
prefix_ok=rows == expected[:len(rows)] and len(rows) >= max(1,len(trust["history"])-1)
identity_ok=len(parts)==5 and int(parts[1])==trust["client_pid"] and int(parts[2])==trust["backend_pid"]
lock_count=int(scalar(f"select count(*) from pg_locks where locktype='advisory' and granted and pid={trust['backend_pid']} and objid={trust['lease_key']}") or 0)
if client_alive:
    lifecycle_ok=backend_alive and parts[0]=="running" and lock_count==1
else:
    lifecycle_ok=parts[0]=="completed" and len(rows)==len(expected) and lock_count==0
ok=prefix_ok and identity_ok and lifecycle_ok
print(f"PEER_OK={int(ok)} original_client_alive={int(client_alive)} original_backend_alive={int(backend_alive)} status={parts[0] if parts else 'missing'} lease_held={lock_count} a_versions={len(rows)} prefix_ok={int(prefix_ok)} identity_ok={int(identity_ok)}")
raise SystemExit(0 if ok else 1)
PY
