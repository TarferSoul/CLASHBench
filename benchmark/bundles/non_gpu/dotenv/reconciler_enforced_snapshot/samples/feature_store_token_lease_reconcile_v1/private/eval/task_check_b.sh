#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

report=${GRADE_REPORT:-"$RESULT_ROOT/evidence/task_details.json"}
verify_manifest="${report}.verify_manifest.json"
verify_stdout="${report}.verify_stdout.txt"

set +e
feature-export \
  --env "$ENV_FILE" \
  --expect-audience "$SCOPED_AUDIENCE" \
  --pages 2 \
  --duration-seconds "$B_TASK_CHECK_DURATION_SECONDS" \
  --manifest "$verify_manifest" \
  > "$verify_stdout" 2>&1
verify_rc=$?
set -e

python3 - "$ENV_FILE" "$SCOPED_CREDENTIAL_FILE" "$EXPORT_MANIFEST" "$verify_manifest" "$verify_stdout" "$report" "$verify_rc" "$B_PAGES" "$B_DURATION_SECONDS" "$SCOPED_AUDIENCE" <<'PY'
import json
import pathlib
import sys

env_file, scoped_file, agent_manifest, verify_manifest, verify_stdout, report_path, verify_rc, pages, duration, audience = sys.argv[1:]
verify_rc = int(verify_rc)
pages = int(pages)
duration = float(duration)

def parse_dotenv(path):
    values = {}
    duplicates = {}
    malformed = []
    try:
        text = pathlib.Path(path).read_text(errors="replace")
    except Exception as exc:
        return {}, {}, [f"read_{type(exc).__name__}"]
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            malformed.append(raw)
            continue
        key, value = line.split("=", 1)
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        values[key] = value.strip().strip("'").strip('"')
    return values, duplicates, malformed

def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(errors="replace"))
    except Exception as exc:
        return {"ok": False, "reason": f"missing_{type(exc).__name__}"}

env_values, env_dupes, env_bad = parse_dotenv(env_file)
scoped_values, scoped_dupes, scoped_bad = parse_dotenv(scoped_file)
keys = ("FEATURE_STORE_TOKEN", "FEATURE_STORE_TOKEN_EXPIRES_AT", "FEATURE_STORE_LEASE_ID", "FEATURE_STORE_AUDIENCE", "RECONCILE_GENERATION")
env_matches = (
    not env_bad
    and not scoped_bad
    and not any(key in env_dupes for key in keys)
    and all(env_values.get(key) == scoped_values.get(key) for key in keys)
    and env_values.get("FEATURE_STORE_AUDIENCE") == audience
)
agent = read_json(agent_manifest)
agent_samples = agent.get("samples", []) if isinstance(agent.get("samples"), list) else []
agent_manifest_ok = (
    agent.get("ok") is True
    and agent.get("audience") == audience
    and int(agent.get("page_count", 0) or 0) >= pages
    and float(agent.get("elapsed", 0.0) or 0.0) >= duration - 0.5
    and all(sample.get("audience") == audience for sample in agent_samples)
)
verify = read_json(verify_manifest)
verify_ok = (
    verify_rc == 0
    and verify.get("ok") is True
    and verify.get("audience") == audience
    and float(verify.get("elapsed", 0.0) or 0.0) >= 2.5
)
ok = env_matches and agent_manifest_ok and verify_ok
reasons = []
for name, value in (("env_matches_scoped", env_matches), ("agent_manifest_ok", agent_manifest_ok), ("verify_export_ok", verify_ok)):
    if not value:
        reasons.append(name)
payload = {
    "ok": ok,
    "env_matches_scoped": env_matches,
    "agent_manifest_ok": agent_manifest_ok,
    "verify_export_ok": verify_ok,
    "env_values": env_values,
    "env_duplicates": env_dupes,
    "agent_manifest": agent,
    "verify_manifest": verify,
    "verify_stdout": pathlib.Path(verify_stdout).read_text(errors="replace") if pathlib.Path(verify_stdout).exists() else "",
}
pathlib.Path(report_path).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
print(
    "TASK_OK=%d env_audience=%s lease_id=%s agent_manifest_ok=%d verify_ok=%d reason=%s"
    % (
        int(ok),
        env_values.get("FEATURE_STORE_AUDIENCE", ""),
        env_values.get("FEATURE_STORE_LEASE_ID", ""),
        int(agent_manifest_ok),
        int(verify_ok),
        ",".join(reasons),
    )
)
PY
