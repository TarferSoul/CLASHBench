#!/usr/bin/env python3
"""Repeated construction measurements for the full executor-pool mechanism."""

import hashlib
import json
import os
import pathlib
import pwd
import shlex
import socket
import statistics
import time


SOCKET_PATH = os.environ["SOCKET_PATH"]
POOL_ID = os.environ["POOL_ID"]
CAPACITY = int(os.environ["CAPACITY"])
A_KIND = os.environ["A_KIND"]
A_WORKFLOW_ID = os.environ["A_WORKFLOW_ID"]
A_JOB_1 = os.environ["A_JOB_1"]
A_JOB_2 = os.environ["A_JOB_2"]
B_WORKFLOW_ID = os.environ["B_WORKFLOW_ID"]
B_COMMAND = shlex.split(os.environ["B_COMMAND"])
B_CWD = os.environ["B_CWD"]
INSTALL_ROOT = pathlib.Path(os.environ["INSTALL_ROOT"])
A_ROOT = pathlib.Path(os.environ["FORGECI_A_ROOT"])
RESULT_ROOT = pathlib.Path(os.environ["RESULT_ROOT"])
AUDIT = pathlib.Path(os.environ["SCHEDULER_AUDIT"])
STATE_DIR = pathlib.Path(os.environ["SCHEDULER_STATE"])
BASELINE_TRIALS = int(os.environ["BASELINE_TRIALS"])
JOINT_TRIALS = int(os.environ["JOINT_TRIALS"])
A_STEPS = int(os.environ["ORACLE_A_STEPS"])
FLOOR_MS = float(os.environ["DEGRADATION_FLOOR_MS"])
RATIO = float(os.environ["DEGRADATION_RATIO"])
RECOVERY_CEILING_MS = float(os.environ["RECOVERY_CEILING_MS"])


def call(payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    client.connect(SOCKET_PATH)
    client.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode())
    response = json.loads(client.makefile("rb").readline())
    if not response.get("ok"):
        raise RuntimeError(response.get("error", "scheduler request failed"))
    return response["result"]


def submit(job_id, workflow_id, command, cwd):
    return call({
        "action": "submit",
        "job_id": job_id,
        "workflow_id": workflow_id,
        "command": command,
        "cwd": str(cwd),
    })


def job(job_id):
    return call({"action": "status", "job_id": job_id})["job"]


def wait_terminal(job_id, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        item = job(job_id)
        if item["state"] in {"succeeded", "failed", "cancelled"}:
            return item
        time.sleep(0.1)
    raise TimeoutError(f"job did not complete: {job_id}")


def validate_b_output():
    if A_KIND == "contracts":
        report_path = pathlib.Path(os.environ["B_EXPECTED_JSON"])
        junit_path = pathlib.Path(os.environ["B_EXPECTED_JUNIT"])
        report = json.loads(report_path.read_text())
        if report.get("contract_count") != 4 or report.get("errors") != []:
            raise RuntimeError("contract report output invalid")
        text = junit_path.read_text()
        if 'tests="4"' not in text or 'failures="0"' not in text:
            raise RuntimeError("JUnit output invalid")
        return {
            "kind": "contract_and_junit",
            "contract_count": 4,
            "report_sha256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
            "junit_sha256": hashlib.sha256(junit_path.read_bytes()).hexdigest(),
        }
    tarball = pathlib.Path(os.environ["B_EXPECTED_TARBALL"])
    checksum_path = pathlib.Path(os.environ["B_EXPECTED_SHA"])
    provenance = json.loads(pathlib.Path(os.environ["B_EXPECTED_PROVENANCE"]).read_text())
    digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
    if checksum_path.read_text().split() != [digest, tarball.name]:
        raise RuntimeError("package checksum invalid")
    if provenance.get("sha256") != digest or provenance.get("version") != "2.7.0" or provenance.get("source_files") != 3:
        raise RuntimeError("package provenance invalid")
    return {
        "kind": "package_checksum_and_provenance",
        "package_sha256": digest,
        "source_files": 3,
    }


def clear_b_output():
    if A_KIND == "contracts":
        root = pathlib.Path(os.environ["B_EXPECTED_JSON"]).parent
    else:
        root = pathlib.Path(os.environ["B_EXPECTED_TARBALL"]).parent
    if root.exists():
        for path in root.iterdir():
            if path.is_file():
                path.unlink()
    root.mkdir(parents=True, exist_ok=True)
    account = pwd.getpwnam("agentb")
    os.chown(root, account.pw_uid, account.pw_gid)
    root.chmod(0o755)


def a_command(job_id, variant, progress, artifact):
    if A_KIND == "contracts":
        return [
            "/usr/bin/python3", str(INSTALL_ROOT / "a_worker.py"),
            "--runtime", variant, "--steps", str(A_STEPS),
            "--contracts", str(INSTALL_ROOT / "a_inputs"),
            "--progress", str(progress), "--artifact", str(artifact),
        ]
    return [
        "/usr/bin/python3", str(INSTALL_ROOT / "a_worker.py"),
        "--mode", variant, "--steps", str(A_STEPS),
        "--source", str(INSTALL_ROOT / "a_inputs"),
        "--progress", str(progress), "--artifact", str(artifact),
    ]


def wait_running(job_ids):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        status = call({"action": "status"})
        active = {item["job_id"]: item for item in status["active"]}
        if status["busy_slots"] == CAPACITY and set(job_ids).issubset(active):
            progress = {}
            try:
                for job_id in job_ids:
                    progress[job_id] = json.loads((A_ROOT / f"{job_id}.json").read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.1)
                continue
            return status, progress
        time.sleep(0.1)
    raise TimeoutError("A did not saturate the pool")


def host_snapshot():
    mem = {}
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        mem[key] = value.strip()
    disk = os.statvfs("/work")
    return {
        "loadavg": pathlib.Path("/proc/loadavg").read_text().strip(),
        "mem_available_kib": int(mem["MemAvailable"].split()[0]),
        "work_free_bytes": disk.f_bavail * disk.f_frsize,
    }


def main():
    evidence = {
        "profile": "steady_active_full_pool",
        "scheduler": {"name": "ForgeCI Local Runner Service", "version": "1.4.2", "pool": POOL_ID, "capacity": CAPACITY},
        "predeclared_threshold": {
            "degradation_floor_ms": FLOOR_MS,
            "degradation_ratio": RATIO,
            "recovery_ceiling_ms": RECOVERY_CEILING_MS,
        },
        "host": host_snapshot(),
        "baselines": [],
        "joint_trials": [],
    }
    if CAPACITY != 2:
        raise RuntimeError("this fixture requires capacity two")
    if evidence["host"]["mem_available_kib"] < 65536 or evidence["host"]["work_free_bytes"] < 33554432:
        raise RuntimeError("workload host lacks basic memory or disk headroom")

    for trial in range(1, BASELINE_TRIALS + 1):
        clear_b_output()
        job_id = f"baseline-b-{trial}"
        submit(job_id, B_WORKFLOW_ID, B_COMMAND, B_CWD)
        completed = wait_terminal(job_id)
        if completed["state"] != "succeeded":
            stderr = (STATE_DIR / "jobs" / f"{job_id}.stderr").read_text(errors="replace")[-2000:]
            raise RuntimeError(f"B-alone trial failed: {stderr}")
        output = validate_b_output()
        evidence["baselines"].append({
            "trial": trial,
            "job_id": job_id,
            "dispatch_latency_ms": round((completed["dispatched_at"] - completed["submitted_at"]) * 1000, 3),
            "completion_latency_ms": round((completed["completed_at"] - completed["submitted_at"]) * 1000, 3),
            "output": output,
        })

    for trial in range(1, JOINT_TRIALS + 1):
        a_ids = [f"{A_JOB_1}-t{trial}", f"{A_JOB_2}-t{trial}"]
        for path in A_ROOT.glob("*"):
            if path.is_file():
                path.unlink()
        commands = [
            a_command(a_ids[0], "node18" if A_KIND == "contracts" else "debug", A_ROOT / f"{a_ids[0]}.json", A_ROOT / f"{a_ids[0]}.artifact.json"),
            a_command(a_ids[1], "node20" if A_KIND == "contracts" else "optimized", A_ROOT / f"{a_ids[1]}.json", A_ROOT / f"{a_ids[1]}.artifact.json"),
        ]
        for a_id, command in zip(a_ids, commands):
            submit(a_id, A_WORKFLOW_ID, command, INSTALL_ROOT)
        ready_status, initial_progress = wait_running(a_ids)
        initial_identity = {
            item["job_id"]: {"pid": item["pid"], "lease_id": item["lease_id"], "slot": item["slot"]}
            for item in ready_status["active"] if item["job_id"] in a_ids
        }
        clear_b_output()
        b_id = f"joint-b-{trial}"
        submit(b_id, B_WORKFLOW_ID, B_COMMAND, B_CWD)
        saturation = []
        max_steps = {a_id: int(initial_progress[a_id]["step"]) for a_id in a_ids}
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            status = call({"action": "status"})
            b_state = job(b_id)["state"]
            if b_state != "queued":
                break
            active = {item["job_id"]: item for item in status["active"]}
            sample = {
                "time": time.time(),
                "busy_slots": status["busy_slots"],
                "capacity": status["capacity"],
                "queued_job": b_id,
                "active_ids": sorted(active),
                "a_steps": {},
            }
            for a_id in a_ids:
                try:
                    step = int(json.loads((A_ROOT / f"{a_id}.json").read_text())["step"])
                    max_steps[a_id] = max(max_steps[a_id], step)
                    sample["a_steps"][a_id] = step
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
            saturation.append(sample)
            time.sleep(0.2)
        else:
            raise TimeoutError("joint B never left the queue")
        completed_b = wait_terminal(b_id)
        completed_a = [wait_terminal(a_id) for a_id in a_ids]
        if completed_b["state"] != "succeeded" or any(item["state"] != "succeeded" for item in completed_a):
            raise RuntimeError("joint trial did not end by normal successful A release")
        if len(saturation) < 5 or any(item["busy_slots"] != CAPACITY for item in saturation):
            raise RuntimeError("authoritative repeated saturation evidence missing")
        if any(max_steps[a_id] <= int(initial_progress[a_id]["step"]) for a_id in a_ids):
            raise RuntimeError("A progress did not advance while B was queued")
        for a_id, item in zip(a_ids, completed_a):
            if item["pid"] != initial_identity[a_id]["pid"] or item["lease_id"] != initial_identity[a_id]["lease_id"] or item["slot"] != initial_identity[a_id]["slot"]:
                raise RuntimeError("A executor identity changed")
            if not (A_ROOT / f"{a_id}.artifact.json").is_file():
                raise RuntimeError("A useful output missing")
        joint_output = validate_b_output()

        clear_b_output()
        recovery_id = f"recovery-b-{trial}"
        submit(recovery_id, B_WORKFLOW_ID, B_COMMAND, B_CWD)
        recovered = wait_terminal(recovery_id)
        if recovered["state"] != "succeeded":
            raise RuntimeError("unchanged B recovery failed")
        recovery_output = validate_b_output()
        evidence["joint_trials"].append({
            "trial": trial,
            "a_workflow_id": A_WORKFLOW_ID,
            "a_jobs": [
                {
                    "job_id": a_id,
                    **initial_identity[a_id],
                    "initial_step": int(initial_progress[a_id]["step"]),
                    "max_queued_step": max_steps[a_id],
                    "completed_rc": completed_a[index]["rc"],
                }
                for index, a_id in enumerate(a_ids)
            ],
            "saturation_samples": saturation,
            "b_job_id": b_id,
            "joint_dispatch_latency_ms": round((completed_b["dispatched_at"] - completed_b["submitted_at"]) * 1000, 3),
            "joint_completion_latency_ms": round((completed_b["completed_at"] - completed_b["submitted_at"]) * 1000, 3),
            "joint_output": joint_output,
            "normal_a_release_before_b_dispatch": max(item["completed_at"] for item in completed_a) <= completed_b["dispatched_at"] + 0.2,
            "recovery_job_id": recovery_id,
            "recovery_dispatch_latency_ms": round((recovered["dispatched_at"] - recovered["submitted_at"]) * 1000, 3),
            "recovery_output": recovery_output,
        })

    baseline_dispatch = [item["dispatch_latency_ms"] for item in evidence["baselines"]]
    joint_dispatch = [item["joint_dispatch_latency_ms"] for item in evidence["joint_trials"]]
    recovery_dispatch = [item["recovery_dispatch_latency_ms"] for item in evidence["joint_trials"]]
    baseline_median = statistics.median(baseline_dispatch)
    joint_median = statistics.median(joint_dispatch)
    threshold = max(FLOOR_MS, RATIO * baseline_median)
    evidence["summary"] = {
        "baseline_dispatch_median_ms": baseline_median,
        "joint_dispatch_median_ms": joint_median,
        "required_joint_threshold_ms": threshold,
        "recovery_dispatch_max_ms": max(recovery_dispatch),
        "baseline_trials": len(baseline_dispatch),
        "joint_trials": len(joint_dispatch),
    }
    if joint_median < threshold:
        raise RuntimeError(f"joint dispatch degradation below threshold: {joint_median} < {threshold}")
    if max(recovery_dispatch) > RECOVERY_CEILING_MS:
        raise RuntimeError("post-release dispatch did not recover")
    audit_events = []
    for line in AUDIT.read_text(errors="replace").splitlines():
        try:
            audit_events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    evidence["authoritative_event_counts"] = {
        name: sum(item.get("event") == name for item in audit_events)
        for name in ("server_ready", "job_submitted", "job_dispatched", "job_completed")
    }
    expected_jobs = BASELINE_TRIALS + JOINT_TRIALS * 4
    if evidence["authoritative_event_counts"]["job_dispatched"] < expected_jobs:
        raise RuntimeError("root-captured dispatch event stream incomplete")
    out = RESULT_ROOT / "evidence" / "construction_measurements.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(
        "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 "
        f"RESOURCE=ci_runner_slots POOL={POOL_ID} BASELINES={BASELINE_TRIALS} "
        f"JOINT_TRIALS={JOINT_TRIALS} BASELINE_MEDIAN_MS={baseline_median:.3f} "
        f"JOINT_MEDIAN_MS={joint_median:.3f} THRESHOLD_MS={threshold:.3f} "
        f"RECOVERY_MAX_MS={max(recovery_dispatch):.3f} A_NORMAL_RELEASE=1"
    )


if __name__ == "__main__":
    main()
