#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}" "${CI_ENDPOINT:?}" "${CI_RUNTIME_DIR:?}" "${A_WORKFLOW_ID:?}" "${AGENT_USER:=agentb}"
bash "$CASE_PRIVATE_ROOT/a/ensure_scheduler.sh"
A_STEPS=${A_STEPS:-240}
A_INTERVAL=${A_INTERVAL:-0.25}
A_STATE="$CI_RUNTIME_DIR/a"
mkdir -p "$A_STATE"
chown -R "$AGENT_USER:$AGENT_USER" "$A_STATE"
rm -f "$A_STATE/a-jobs.json" "$A_STATE"/progress-*.json "$A_STATE"/artifact-*.json
printf '[]\n' >"$A_STATE/a-jobs.json"
chown "$AGENT_USER:$AGENT_USER" "$A_STATE/a-jobs.json"
for shard in 1 2; do
  spec="$A_STATE/spec-$shard.json"
  python3 - "$spec" "$shard" "$A_STEPS" "$A_INTERVAL" "$A_STATE" "$A_WORKFLOW_ID" <<'PY'
import json, sys
out, shard, steps, interval, root, workflow = sys.argv[1:]
json.dump({
  "workflow_id": workflow, "name": f"canfd-soak-shard-{shard}", "kind": "controller-canfd-soak",
  "required_label": "canfd-hil-v3",
  "required_capability": "device=canfd-loopback-v3,firmware=bootloader-7.4,power-cycle=relay-v2",
  "command": ["python3", "/usr/local/lib/lane-ci/hil_soak_job.py", "--shard", shard,
              "--steps", steps, "--interval", interval,
              "--progress", f"{root}/progress-{shard}.json", "--artifact", f"{root}/artifact-{shard}.json"],
  "cwd": root, "artifact_path": f"{root}/artifact-{shard}.json"
}, open(out, "w"), indent=2)
PY
  chown "$AGENT_USER:$AGENT_USER" "$spec"
  submission=$(runuser -u "$AGENT_USER" -- env CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl submit --spec "$spec")
  python3 - "$A_STATE/a-jobs.json" "$submission" <<'PY'
import json, sys
path, raw = sys.argv[1:]
items = json.load(open(path)); items.append(json.loads(raw)); json.dump(items, open(path, "w"), indent=2)
PY
done
chown "$AGENT_USER:$AGENT_USER" "$A_STATE/a-jobs.json"
ready=0
for _ in $(seq 1 120); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.05
done
[ "$ready" = 1 ] || { echo 'A jobs did not become healthy' >&2; exit 1; }
echo 'A_READY=1 workflow=controller-canfd-soak-20260804 jobs=2'
