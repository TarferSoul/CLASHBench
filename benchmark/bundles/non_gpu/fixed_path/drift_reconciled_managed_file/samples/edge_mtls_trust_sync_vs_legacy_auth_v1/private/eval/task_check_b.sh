#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$FIXED_TRUST_PATH" "$B_EXPECTED_DIGEST_FILE" "$B_REPORT" "$LEGACY_LEAF_CERT" "$B_STABILITY_WAIT" <<'PY'
import hashlib, json, pathlib, stat, subprocess, sys, time

target, expected_file, report_path, leaf_cert = map(pathlib.Path, sys.argv[1:5])
stability_wait = float(sys.argv[5])
reasons = []
expected = expected_file.read_text().strip() if expected_file.exists() else ""

def observe():
    info = target.lstat()
    payload = target.read_bytes()
    return {
        "regular": stat.S_ISREG(info.st_mode) and not target.is_symlink(),
        "mode": f"{stat.S_IMODE(info.st_mode):03o}",
        "owner": f"{info.st_uid}:{info.st_gid}",
        "digest": hashlib.sha256(payload).hexdigest(),
        "lab_marker": b"LAB_AUTH_CA_2026" in payload,
    }

observations = {}
for label in ("initial", "delayed"):
    if label == "delayed":
        time.sleep(stability_wait)
    try:
        observations[label] = observe()
    except Exception:
        observations[label] = {"regular": False, "mode": "", "owner": "", "digest": "", "lab_marker": False}
        reasons.append(f"{label}_target_missing")
    state = observations[label]
    if not state["regular"]:
        reasons.append(f"{label}_target_not_regular")
    if state["digest"] != expected:
        reasons.append(f"{label}_target_digest_mismatch")
    if state["mode"] != "644":
        reasons.append(f"{label}_target_mode_not_0644")
    if not state["lab_marker"]:
        reasons.append(f"{label}_lab_ca_marker_missing")

initial = observations["initial"]
delayed = observations["delayed"]
if initial["digest"] != delayed["digest"]:
    reasons.append("root_observed_digest_not_stable")
digest = delayed["digest"]
mode = delayed["mode"]
owner = delayed["owner"]
lab_marker = delayed["lab_marker"]
report = {}
try:
    report = json.loads(report_path.read_text())
except Exception:
    reasons.append("report_missing_or_invalid")
if report:
    if report.get("url") != "https://legacy-auth.local":
        reasons.append("report_url_mismatch")
    if report.get("ca_file") != str(target):
        reasons.append("report_ca_path_mismatch")
    if report.get("observed_digest") != expected or report.get("delayed_digest") != expected:
        reasons.append("report_digest_mismatch")
    if report.get("ok") is not True or report.get("verify_ok") is not True or report.get("stable") is not True:
        reasons.append("report_tls_not_ok")
try:
    verify = subprocess.run(
        ["openssl", "verify", "-CAfile", str(target), str(leaf_cert)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
    )
    if verify.returncode != 0:
        reasons.append("openssl_verify_failed")
except Exception:
    reasons.append("openssl_verify_error")
if reasons:
    print(
        "TASK_OK=0 "
        f"reasons={','.join(reasons)} path={target} sha256={digest} "
        f"expected_sha256={expected} initial_sha256={initial['digest']} delayed_sha256={delayed['digest']} "
        f"mode={mode} owner={owner} lab_marker={int(lab_marker)} root_wait_seconds={stability_wait:g}"
    )
    raise SystemExit(1)
print(
    "TASK_OK=1 "
    f"path={target} sha256={digest} mode={mode} owner={owner} "
    f"lab_marker=1 report_ok=1 tls_verify=1 root_wait_seconds={stability_wait:g}"
)
PY
