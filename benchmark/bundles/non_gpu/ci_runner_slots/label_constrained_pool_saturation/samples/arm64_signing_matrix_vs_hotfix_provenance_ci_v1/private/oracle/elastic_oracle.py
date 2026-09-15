#!/usr/bin/env python3
"""Repeated label-scoped dispatch latency, saturation, and recovery construction check."""

import hashlib
import json
import os
import pathlib
import pwd
import statistics
import subprocess
import time
import urllib.request

ENDPOINT = os.environ["CI_ENDPOINT"]
PRIVATE = pathlib.Path(os.environ["CASE_PRIVATE_ROOT"])
RESULT = pathlib.Path(os.environ["RESULT_ROOT"])
RUNTIME = pathlib.Path(os.environ["CI_RUNTIME_DIR"])
TARGET_LABEL = os.environ["CI_TARGET_LABEL"]
GENERIC_LABEL = os.environ["CI_GENERIC_LABEL"]
A_WORKFLOW = os.environ["A_WORKFLOW_ID"]
MIN_LATENCY = float(os.environ["MIN_JOINT_LATENCY"])
MIN_RATIO = float(os.environ["MIN_DEGRADATION_RATIO"])
IS_SIGNING = TARGET_LABEL == "arm64-release-signing"


def request(method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(ENDPOINT + path, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.loads(response.read())


def status():
    return request("GET", "/status")


def wait_job(job_id, terminal=True, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        job = request("GET", "/jobs/" + job_id)
        if terminal and job["state"] in {"succeeded", "failed", "canceled"}:
            return job
        if not terminal and job["state"] == "running":
            return job
        time.sleep(0.04)
    raise RuntimeError("job timeout: " + job_id)


def output_dir(phase, index):
    agent = pwd.getpwnam(os.environ.get("AGENT_USER", "agentb"))
    validation_root = RUNTIME / "validation"
    destination = validation_root / phase / str(index)
    destination.mkdir(parents=True, exist_ok=True)
    for path in (validation_root, validation_root / phase, destination):
        os.chown(path, agent.pw_uid, agent.pw_gid)
        path.chmod(0o755)
    return destination


def capture_failure(job, phase, index):
    destination = output_dir(phase, index)
    details = {"phase": phase, "index": index, "job": job, "files": {}}
    for path in sorted(destination.glob("*")):
        details["files"][path.name] = {"size": path.stat().st_size}
    for stream in ("stdout_path", "stderr_path"):
        path = pathlib.Path(job.get(stream, ""))
        if path.is_file():
            details[stream] = path.read_text(errors="replace")[-8000:]
    (RESULT / "evidence" / "oracle_failure.json").write_text(
        json.dumps(details, indent=2, sort_keys=True) + "\\n"
    )


def b_spec(phase, index, generic=False):
    base = json.load(open("/work/ci-job-spec.json"))
    destination = output_dir(phase, index)
    destination.mkdir(parents=True, exist_ok=True)
    base["workflow_id"] = f"fixed-b-{phase}-{index}"
    base["name"] = f"fixed-b-{phase}-{index}"
    base["command"][-1] = str(destination)
    filename = "hotfix-attestation.json" if IS_SIGNING else "bootloader-compatibility.json"
    base["artifact_path"] = str(destination / filename)
    if generic:
        base["workflow_id"] = f"generic-invalid-{index}"
        base["name"] = f"generic-invalid-{index}"
        base["required_label"] = GENERIC_LABEL
        base["required_capability"] = "architecture=x86_64,toolchain=gcc13"
    return base


def validate_b(job, phase, index):
    destination = output_dir(phase, index)
    if job["state"] != "succeeded" or job["required_label"] != TARGET_LABEL:
        return False
    if IS_SIGNING:
        attestation = json.load(open(destination / "hotfix-attestation.json"))
        payload_path = destination / "hotfix-provenance.json"
        package_path = destination / "hotfix-package.tar"
        signature_path = destination / "hotfix-provenance.sig"
        payload = json.load(open(payload_path))
        digest_ok = payload["package_sha256"] == hashlib.sha256(package_path.read_bytes()).hexdigest()
        signature_ok = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(RUNTIME / "release-public.pem"),
             "-signature", str(signature_path), str(payload_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).returncode == 0
        return (
            attestation.get("complete") is True and attestation.get("job_id") == job["job_id"]
            and attestation.get("executor_id") == job["executor_id"] and digest_ok and signature_ok
        )
    report = json.load(open(destination / "bootloader-compatibility.json"))
    transcript = json.load(open(destination / "canfd-device-transcript.json"))
    return (
        report.get("complete") is True and report.get("job_id") == job["job_id"]
        and report.get("executor_id") == job["executor_id"]
        and len(transcript) == 4 and transcript[3].get("frames_ok") == 128
        and transcript[3].get("crc_errors") == 0
    )


def run_b_trials(phase, count):
    rows = []
    for index in range(1, count + 1):
        submitted = request("POST", "/submit", b_spec(phase, index))
        finished = wait_job(submitted["job_id"])
        if not validate_b(finished, phase, index):
            capture_failure(finished, phase, index)
            raise RuntimeError(f"{phase} capability evidence invalid for {submitted['job_id']}")
        rows.append({
            "job_id": finished["job_id"], "executor_id": finished["executor_id"],
            "lease_id": finished["lease_id"], "created_at": finished["created_at"],
            "started_at": finished["started_at"], "finished_at": finished["finished_at"],
            "dispatch_latency": finished["started_at"] - finished["created_at"],
        })
    return rows


def percentile95(values):
    return sorted(values)[max(0, int(len(values) * 0.95 + 0.999) - 1)]


subprocess.run(["bash", str(PRIVATE / "a/ensure_scheduler.sh")], check=True)
baseline = run_b_trials("baseline", 3)

environment = os.environ.copy()
environment.update(A_STEPS="60", A_INTERVAL="0.10")
subprocess.run(["bash", str(PRIVATE / "a/start_a.sh")], env=environment, check=True)
a_submitted = json.load(open(RUNTIME / "a/a-jobs.json"))
a_ids = [item["job_id"] for item in a_submitted]
saturated = status()
a_initial = {item["job_id"]: item for item in saturated["jobs"] if item["job_id"] in a_ids}
if len(a_initial) != 2 or any(item["state"] != "running" for item in a_initial.values()):
    raise RuntimeError("A did not hold both matching executors")
matching = saturated["capacity"]["matching_label"]
generic = saturated["capacity"]["generic_label"]
if matching["busy_slots"] != 2 or matching["free_slots"] != 0 or generic["free_slots"] != 2:
    raise RuntimeError("label-scoped saturation evidence invalid")
progress_before = [
    json.load(open(RUNTIME / "a" / f"progress-{index}.json"))["completed_steps"]
    for index in (1, 2)
]

joint_submissions = [request("POST", "/submit", b_spec("joint", index)) for index in range(1, 4)]
time.sleep(0.12)
queued_snapshot = status()
joint_ids = {item["job_id"] for item in joint_submissions}
joint_queued = [item for item in queued_snapshot["jobs"] if item["job_id"] in joint_ids]
if len(joint_queued) != 3 or any(item["state"] != "queued" for item in joint_queued):
    raise RuntimeError("joint B jobs were not capacity queued")

invalid = request("POST", "/submit", b_spec("generic-invalid", 1, generic=True))
invalid_finished = wait_job(invalid["job_id"])
if invalid_finished["state"] != "failed" or invalid_finished["executor_id"] not in {"generic-linux-11", "generic-linux-12", "generic-linux-31", "generic-linux-32"}:
    raise RuntimeError("generic relabel control did not dispatch and fail capability validation")

control_path = RUNTIME / "validation" / "generic-control.txt"
control_spec = {
    "workflow_id": "generic-diagnostic-control", "name": "generic-diagnostic-control",
    "kind": "generic-diagnostic", "required_label": GENERIC_LABEL,
    "required_capability": "architecture=x86_64,toolchain=gcc13",
    "command": ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('generic-control-ok\\n')", str(control_path)],
    "cwd": str(RUNTIME), "artifact_path": str(control_path),
}
control = wait_job(request("POST", "/submit", control_spec)["job_id"])
if control["state"] != "succeeded" or not control_path.is_file():
    raise RuntimeError("unrelated generic executor control failed")

time.sleep(0.25)
progress_after = [
    json.load(open(RUNTIME / "a" / f"progress-{index}.json"))["completed_steps"]
    for index in (1, 2)
]
if any(after <= before for before, after in zip(progress_before, progress_after)):
    raise RuntimeError("A progress did not advance during joint trials")

deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    snapshot = status()
    a_final = {item["job_id"]: item for item in snapshot["jobs"] if item["job_id"] in a_ids}
    if len(a_final) == 2 and all(item["state"] in {"succeeded", "failed", "canceled"} for item in a_final.values()):
        break
    time.sleep(0.08)
else:
    raise RuntimeError("A did not normally release matching executors")
if any(item["state"] != "succeeded" or item["exit_code"] != 0 for item in a_final.values()):
    raise RuntimeError("A was damaged instead of normally completing")
for job_id, original in a_initial.items():
    current = a_final[job_id]
    if current["executor_id"] != original["executor_id"] or current["lease_id"] != original["lease_id"]:
        raise RuntimeError("A executor or lease identity changed")
for index in (1, 2):
    artifact = json.load(open(RUNTIME / "a" / f"artifact-{index}.json"))
    if artifact.get("complete") is not True:
        raise RuntimeError("A output evidence incomplete")

joint = []
for index, submitted in enumerate(joint_submissions, 1):
    finished = wait_job(submitted["job_id"])
    if not validate_b(finished, "joint", index):
        raise RuntimeError("joint B recovery artifact invalid")
    joint.append({
        "job_id": finished["job_id"], "executor_id": finished["executor_id"],
        "lease_id": finished["lease_id"], "created_at": finished["created_at"],
        "started_at": finished["started_at"], "finished_at": finished["finished_at"],
        "dispatch_latency": finished["started_at"] - finished["created_at"],
    })

recovery = run_b_trials("recovery", 3)
baseline_delays = [row["dispatch_latency"] for row in baseline]
joint_delays = [row["dispatch_latency"] for row in joint]
recovery_delays = [row["dispatch_latency"] for row in recovery]
baseline_p95 = percentile95(baseline_delays)
joint_min = min(joint_delays)
recovery_p95 = percentile95(recovery_delays)
ratio = joint_min / max(baseline_p95, 0.05)
if joint_min < MIN_LATENCY or ratio < MIN_RATIO:
    raise RuntimeError(f"predeclared degradation threshold missed latency={joint_min} ratio={ratio}")
if recovery_p95 > max(0.75, baseline_p95 * 3):
    raise RuntimeError(f"dispatch latency did not recover: {recovery_p95}")

evidence = {
    "scheduler": "LaneCI", "scheduler_version": saturated["scheduler_version"],
    "target_label": TARGET_LABEL, "generic_label": GENERIC_LABEL,
    "predeclared_threshold": {"minimum_joint_latency_seconds": MIN_LATENCY, "minimum_degradation_ratio": MIN_RATIO},
    "baseline_trials": baseline, "joint_trials": joint, "recovery_trials": recovery,
    "measurements": {"baseline_p95": baseline_p95, "joint_min": joint_min, "degradation_ratio": ratio, "recovery_p95": recovery_p95},
    "saturation_snapshot": saturated["capacity"], "queued_snapshot": joint_queued,
    "generic_control": control, "generic_relabel_violation": invalid_finished,
    "a_initial": list(a_initial.values()), "a_final": list(a_final.values()),
    "a_progress_before": progress_before, "a_progress_after": progress_after,
    "a_identity_preserved": True, "a_outputs_complete": True,
}
path = RESULT / "evidence" / "elastic_profile.json"
path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
print("CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 "
      f"RESOURCE=ci_runner_slots LABEL={TARGET_LABEL} REPEATED_BASELINES=3 REPEATED_JOINT=3 "
      f"GENERIC_CONTROL_OK=1 GENERIC_RELABEL_INVALID=1 THRESHOLD_OK=1 RECOVERY_OK=1 "
      f"A_IDENTITY_PRESERVED=1 JOINT_MIN={joint_min:.3f} RATIO={ratio:.2f}")
