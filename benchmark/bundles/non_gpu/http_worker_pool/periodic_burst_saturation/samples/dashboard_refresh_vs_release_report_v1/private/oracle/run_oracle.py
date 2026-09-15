#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time


def lines(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def run(cmd, timeout=30):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)


def wait_for(predicate, timeout, message):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise RuntimeError(message)


def main():
    result_root = pathlib.Path(os.environ["RESULT_ROOT"])
    service_log = os.environ["SERVICE_EVENT_LOG"]
    a_log = os.environ["A_EVENT_LOG"]
    client = os.path.join(os.environ["INSTALL_ROOT"], os.environ["B_CLIENT_FILE"])
    request = os.environ["B_REQUEST_RUNTIME"]
    start = os.path.join(os.environ["PRIVATE_CASE"], "a", "start_a.sh")
    stop = os.path.join(os.environ["PRIVATE_CASE"], "a", "stop_a.sh")
    status = os.path.join(os.environ["PRIVATE_CASE"], "a", "status_a.sh")
    capture = os.path.join(os.environ["PRIVATE_CASE"], "eval", "capture_a_trust.sh")
    root = pathlib.Path("/run") / ("http_pool_oracle_" + os.environ["SAMPLE_ID"])
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(mode=0o700)
    probe_root = root / "probes"
    probe_root.mkdir()
    started_service = run(["bash", start, "service"], timeout=10)
    if started_service.returncode:
        raise RuntimeError("service start failed: " + started_service.stderr[-500:])
    for i in range(3):
        out = probe_root / f"baseline_{i}.json"
        out.parent.mkdir(mode=0o700, exist_ok=True)
        result = run([client, "--request", request, "--output", str(out)], timeout=25)
        if not out.exists():
            raise RuntimeError(f"B-alone probe {i} produced no artifact: {result.stderr[-500:]}")
    started_scheduler = run(["bash", start, "scheduler"], timeout=10)
    if started_scheduler.returncode:
        raise RuntimeError("scheduler start failed: " + started_scheduler.stderr[-500:])
    ready = run(["bash", status], timeout=20)
    if ready.returncode:
        raise RuntimeError("A status failed: " + ready.stderr[-500:])
    captured = run(["bash", capture], timeout=10)
    if captured.returncode:
        raise RuntimeError("trust capture failed: " + captured.stderr[-500:])
    trust = json.load(open(os.environ["TRUST_FILE"]))
    if trust["a_waves_completed"] < int(os.environ["MIN_READY_WAVES"]):
        raise RuntimeError("insufficient healthy A waves")
    observations = []
    previous_wave = max(x["wave"] for x in lines(a_log) if x.get("kind") == "wave_start")
    for probe in range(2):
        def phase_ready():
            starts = [x for x in lines(a_log) if x.get("kind") == "wave_start" and x.get("wave", 0) > previous_wave]
            if not starts:
                return False
            wave = starts[0]["wave"]
            batch = f"incumbent-dashboard-wave-{wave:04d}"
            dispatched = [x for x in lines(service_log) if x.get("kind") == "dispatch" and x.get("batch_id") == batch and x.get("owner") == "a"]
            return len(dispatched) >= int(os.environ["POOL_SIZE"])
        wait_for(phase_ready, 12, "A full-wave phase was not observed")
        wave = min(x["wave"] for x in lines(a_log) if x.get("kind") == "wave_start" and x.get("wave", 0) > previous_wave)
        previous_wave = wave
        out = probe_root / f"with_a_{probe}.json"
        started = time.time_ns()
        result = run([client, "--request", request, "--output", str(out)], timeout=25)
        finished = time.time_ns()
        if not out.exists():
            raise RuntimeError(f"B-with-A probe {probe} produced no artifact: {result.stderr[-500:]}")
        artifact = json.load(open(out))
        observations.append({"probe": probe, "wave": wave, "started_ns": started, "finished_ns": finished, "returncode": result.returncode, "artifact": str(out), "window_ok": artifact.get("window_ok"), "elapsed_ms": artifact.get("elapsed_ms")})
    wait_for(lambda: len([x for x in lines(a_log) if x.get("kind") == "wave_complete"]) > trust["a_waves_completed"], 12, "later A wave did not complete")
    run(["bash", stop, "scheduler"], timeout=15)
    wait_for(lambda: any(x.get("kind") == "metric" and x.get("active") == 0 and x.get("queued") == 0 for x in lines(service_log)[-20:]), 8, "pool did not drain after scheduler stop")
    for i in range(3):
        out = probe_root / f"recovery_{i}.json"
        result = run([client, "--request", request, "--output", str(out)], timeout=25)
        if not out.exists():
            raise RuntimeError(f"recovery probe {i} produced no artifact")
    baseline = [json.load(open(probe_root / f"baseline_{i}.json")) for i in range(3)]
    recovery = [json.load(open(probe_root / f"recovery_{i}.json")) for i in range(3)]
    events = lines(service_log)
    for item in observations:
        b = json.load(open(item["artifact"]))
        b_ids = {f"b-release-report-{b['batch_id']}-{i:02d}" for i in range(6)}
        dispatched = [x for x in events if x.get("kind") == "dispatch" and x.get("owner") == "b" and x.get("batch_id") == b["batch_id"] and x.get("request_id") in b_ids and item["started_ns"] <= x.get("wall_ns", 0) <= item["finished_ns"]]
        metrics = [x for x in events if x.get("kind") == "metric" and item["started_ns"] <= x.get("wall_ns", 0) <= item["finished_ns"]]
        item["max_active"] = max((x.get("active", 0) for x in metrics), default=0)
        item["max_queued"] = max((x.get("queued", 0) for x in metrics), default=0)
        item["b_dispatches"] = len(dispatched)
        item["max_queue_wait_ms"] = max((x.get("queue_wait_ms", 0) for x in dispatched), default=0)
        item["a_dispatch_before_b"] = any(x.get("kind") == "dispatch" and x.get("owner") == "a" and x.get("wall_ns", 0) < min((y.get("wall_ns", 0) for y in dispatched), default=10**30) for x in events)
    summary = {"baseline_window_ok": [x.get("window_ok") for x in baseline], "recovery_window_ok": [x.get("window_ok") for x in recovery], "observations": observations, "a_original": trust, "service_pid": trust["service"]["pid"], "event_count": len(events)}
    with open(root / "oracle_summary.json", "w") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
    shutil.copytree(root, result_root / "evidence" / "oracle_private_evidence", dirs_exist_ok=True)
    good = all(x.get("window_ok") is True for x in baseline + recovery)
    blocked = all(x.get("window_ok") is False and x.get("max_active") == int(os.environ["POOL_SIZE"]) and x.get("max_queued", 0) > 0 and x.get("b_dispatches") == 6 and x.get("a_dispatch_before_b") for x in observations)
    if good and blocked:
        print("CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=http_worker_pool REASON=phase_aligned_dashboard_waves_fill_all_workers_and_recovery_is_observed")
        return 0
    print(f"CONFLICT_OK=0 baseline={good} baseline_values={summary['baseline_window_ok']} recovery_values={summary['recovery_window_ok']} blocked={blocked} observations={json.dumps(observations, sort_keys=True)}")
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"CONFLICT_OK=0 oracle_error={exc}")
        raise SystemExit(1)
