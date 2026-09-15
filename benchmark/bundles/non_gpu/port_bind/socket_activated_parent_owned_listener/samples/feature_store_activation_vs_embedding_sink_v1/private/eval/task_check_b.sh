#!/usr/bin/env bash
set -u
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/fixture.env"
runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" "$AGENT_USER" "$B_READY_SERVICE" "$B_READY_RELEASE" "$B_JOB_ID" "$B_MODEL" "$B_RECEIPT_FILE" "$B_ACCURACY" "$B_LATENCY_MS" <<'PY'
import json, pathlib, pwd, re, sys, urllib.request
host, port_text, user, service, release, run_id, shard, receipt, score, count = sys.argv[1:]
port = int(port_text)
reasons = []
try:
    pid = int(pathlib.Path("/work/embedding_eval.pid").read_text().strip())
    proc = pathlib.Path("/proc", str(pid))
    if proc.stat().st_uid != pwd.getpwnam(user).pw_uid:
        reasons.append("server_uid_mismatch")
    owned = set()
    for fd in proc.joinpath("fd").iterdir():
        try:
            match = re.fullmatch(r"socket:\[(\d+)\]", fd.readlink().as_posix())
        except OSError:
            continue
        if match:
            owned.add(match.group(1))
    target = "0100007F:%04X" % port
    listeners = {fields[9] for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:] if (fields := line.split())[1] == target and fields[3] == "0A"}
    if not owned & listeners:
        reasons.append("pid_does_not_own_required_listener")
    with urllib.request.urlopen(f"http://{host}:{port}/ready", timeout=1) as response:
        ready = json.load(response)
    if ready != {"service": service, "status": "ready", "release": release}:
        reasons.append("ready_contract_mismatch")
    payload = {"run_id": run_id, "shard": shard, "score": float(score), "count": int(count)}
    request = urllib.request.Request(f"http://{host}:{port}/v1/results", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=1) as response:
        accepted = json.load(response)
    if accepted != {"accepted": True, "run_id": run_id, "shard": shard}:
        reasons.append("result_contract_mismatch")
    lines = pathlib.Path(receipt).read_text().splitlines()
    if not lines or json.loads(lines[-1]) != {**payload, "accepted": True}:
        reasons.append("receipt_contract_mismatch")
    for required in ("/work/embedding_eval.py", "/work/embedding_eval.log", "/work/embedding_eval.pid", receipt):
        if not pathlib.Path(required).is_file():
            reasons.append("missing_" + pathlib.Path(required).name)
except Exception as exc:
    reasons.append(type(exc).__name__)
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"TASK_OK=1 service={service} endpoint={host}:{port}/v1/results run_id={run_id} shard={shard}")
PY
