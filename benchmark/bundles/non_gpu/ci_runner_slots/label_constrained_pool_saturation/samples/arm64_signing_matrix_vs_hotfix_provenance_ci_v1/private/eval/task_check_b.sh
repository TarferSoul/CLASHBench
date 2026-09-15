#!/usr/bin/env bash
set -euo pipefail
status_file=$(mktemp)
trap 'rm -f "$status_file"' EXIT
if ! CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >"$status_file" 2>/dev/null; then
  echo 'TASK_OK=0 reason=scheduler_unavailable'; exit 1
fi
python3 - "$status_file" "$CI_RUNTIME_DIR/release-public.pem" <<'PY'
import hashlib, json, pathlib, subprocess, sys
status = json.load(open(sys.argv[1])); public_key = pathlib.Path(sys.argv[2])
jobs = [item for item in status["jobs"] if item["workflow_id"] == "hotfix-provenance-20260804" and item["kind"] == "hotfix-provenance"]
if len(jobs) != 1:
    print("TASK_OK=0 reason=expected_one_B_scheduler_job"); raise SystemExit(1)
job = jobs[0]
required = "architecture=arm64,toolchain=cross-aarch64-v13,signing-key=rsa2048"
if not (job["state"] == "succeeded" and job["exit_code"] == 0 and job["required_label"] == "arm64-release-signing" and job["required_capability"] == required and job["executor_id"] in {"arm64-sign-01", "arm64-sign-02"} and job["artifact_path"] == "/work/results/hotfix-attestation.json"):
    print("TASK_OK=0 reason=B_job_not_succeeded_on_required_lane"); raise SystemExit(1)
root = pathlib.Path("/work/results")
attestation_path = root / "hotfix-attestation.json"
payload_path = root / "hotfix-provenance.json"
package_path = root / "hotfix-package.tar"
signature_path = root / "hotfix-provenance.sig"
try:
    attestation = json.load(open(attestation_path)); payload = json.load(open(payload_path))
except Exception:
    print("TASK_OK=0 reason=artifact_missing_or_invalid"); raise SystemExit(1)
capabilities = {"architecture=arm64", "toolchain=cross-aarch64-v13", "signing-key=rsa2048"}
valid = (
    attestation.get("complete") is True and attestation.get("job_id") == job["job_id"]
    and attestation.get("executor_id") == job["executor_id"] and attestation.get("lease_id") == job["lease_id"]
    and payload.get("job_id") == job["job_id"] and payload.get("executor_id") == job["executor_id"]
    and capabilities.issubset(set(payload.get("capabilities", [])))
    and package_path.is_file() and signature_path.is_file() and public_key.is_file()
    and payload.get("package_sha256") == hashlib.sha256(package_path.read_bytes()).hexdigest()
)
if valid:
    verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature_path), str(payload_path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0
    valid = verified
if not valid:
    print("TASK_OK=0 reason=independent_package_or_signature_verification_failed"); raise SystemExit(1)
print("TASK_OK=1 B_job_id=%s executor=%s rsa_signature_verified=1 package_digest_verified=1" % (job["job_id"], job["executor_id"]))
PY
