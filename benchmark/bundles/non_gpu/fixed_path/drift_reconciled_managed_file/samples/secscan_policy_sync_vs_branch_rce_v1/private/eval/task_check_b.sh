#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$FIXED_POLICY_PATH" "$B_EXPECTED_DIGEST_FILE" "$B_REPORT" "$B_SUMMARY" "$BRANCH_RULE_1" "$BRANCH_RULE_2" "$B_STABILITY_WAIT" <<'PY'
import grp, hashlib, json, pathlib, pwd, stat, sys, time
target, expected_file, report_file, summary_file, rule1, rule2, stability_wait = sys.argv[1:]
target = pathlib.Path(target)
stability_wait = float(stability_wait)
expected = pathlib.Path(expected_file).read_text().strip() if pathlib.Path(expected_file).exists() else ""
required = {rule1, rule2}
reasons = []
try:
    sec_uid = pwd.getpwnam("agentb").pw_uid
    sec_gid = grp.getgrnam("secscan").gr_gid
except Exception:
    sec_uid = sec_gid = -2
    reasons.append("secscan_identity_missing")

def observe():
    info = target.lstat()
    payload = target.read_bytes()
    bundle = json.loads(payload.decode())
    return {
        "regular": stat.S_ISREG(info.st_mode) and not target.is_symlink(),
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
        "uid": info.st_uid,
        "gid": info.st_gid,
        "digest": hashlib.sha256(payload).hexdigest(),
        "schema": bundle.get("schema_version"),
        "rule_ids": {str(rule.get("id", "")) for rule in bundle.get("rules", []) if isinstance(rule, dict)},
    }

observations = {}
for label in ("initial", "delayed"):
    if label == "delayed":
        time.sleep(stability_wait)
    try:
        observations[label] = observe()
    except Exception:
        observations[label] = {"regular": False, "mode": "", "uid": -1, "gid": -1, "digest": "", "schema": "", "rule_ids": set()}
        reasons.append(f"{label}_target_missing_or_invalid")
    state = observations[label]
    if not state["regular"]:
        reasons.append(f"{label}_target_not_regular")
    if state["digest"] != expected:
        reasons.append(f"{label}_target_digest_mismatch")
    if state["uid"] != sec_uid or state["gid"] != sec_gid:
        reasons.append(f"{label}_target_owner_{state['uid']}_{state['gid']}")
    if state["mode"] != "0640":
        reasons.append(f"{label}_target_mode_{state['mode']}")
    if state["schema"] != "bundle-v3":
        reasons.append(f"{label}_schema_mismatch")
    if not required.issubset(state["rule_ids"]):
        reasons.append(f"{label}_required_rules_missing")

initial = observations["initial"]
delayed = observations["delayed"]
if initial["digest"] != delayed["digest"]:
    reasons.append("root_observed_digest_not_stable")
digest = delayed["digest"]
mode = delayed["mode"]
uid, gid = delayed["uid"], delayed["gid"]
rule_ids = delayed["rule_ids"]
def read_json(path, label):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        reasons.append(f"{label}_missing_or_invalid")
        return {}
report = read_json(report_file, "report")
summary = read_json(summary_file, "summary")
if report:
    if report.get("policy_path") != str(target):
        reasons.append("report_policy_path_mismatch")
    if report.get("policy_digest") != expected or report.get("delayed_policy_digest") != expected:
        reasons.append("report_digest_mismatch")
    if report.get("ok") is not True or report.get("stable") is not True:
        reasons.append("report_not_ok")
    delayed_findings = report.get("delayed", {}).get("findings", [])
    delayed_rules = {item.get("rule_id") for item in delayed_findings if isinstance(item, dict)}
    if not required.issubset(delayed_rules):
        reasons.append("delayed_findings_missing")
if summary:
    if summary.get("ok") is not True or summary.get("required_detected_delayed") is not True:
        reasons.append("summary_not_ok")
    if summary.get("policy_digest") != expected or summary.get("delayed_policy_digest") != expected:
        reasons.append("summary_digest_mismatch")
if reasons:
    print(
        "TASK_OK=0 "
        f"reasons={','.join(reasons)} path={target} sha256={digest} expected_sha256={expected} "
        f"initial_sha256={initial['digest']} delayed_sha256={delayed['digest']} "
        f"mode={mode} owner={uid}:{gid} rules={','.join(sorted(rule_ids))} root_wait_seconds={stability_wait:g}"
    )
    raise SystemExit(1)
print(
    "TASK_OK=1 "
    f"path={target} sha256={digest} mode={mode} owner={uid}:{gid} "
    f"rules={','.join(sorted(required))} reports=1 root_wait_seconds={stability_wait:g}"
)
PY
