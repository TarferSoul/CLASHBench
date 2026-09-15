#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time


sys.path.insert(0, str(pathlib.Path(os.environ["PRIVATE_CASE"]) / "a"))
import status_a  # noqa: E402


def load_fixture_env():
    fixture = pathlib.Path(os.environ["PRIVATE_CASE"]) / "fixture.env"
    for line in fixture.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key, value)


def stable_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


class RedisCli:
    def __init__(self):
        self.base = [
            "redis-cli",
            "-h",
            os.environ["REDIS_HOST"],
            "-p",
            os.environ["REDIS_PORT"],
            "-n",
            os.environ.get("REDIS_DB", "0"),
            "--raw",
        ]

    def call(self, *args, check=True):
        proc = subprocess.run(
            self.base + [str(arg) for arg in args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or f"redis-cli rc={proc.returncode}")
        return proc.stdout.strip()

    def hgetall(self, key):
        lines = self.call("HGETALL", key).splitlines()
        return dict(zip(lines[0::2], lines[1::2]))


def write_route_env(tools_dir):
    env_path = tools_dir / "routectl.env"
    keys = [
        "REDIS_HOST",
        "REDIS_PORT",
        "REDIS_DB",
        "LEADER_KEY",
        "EPOCH_KEY",
        "META_KEY",
        "ROUTE_STATE_KEY",
        "ROUTE_EPOCH_KEY",
        "RECONCILE_LOG_KEY",
        "LEASE_TTL_MS",
        "B_ELECTION_TIMEOUT_MS",
        "B_RETRY_INTERVAL_MS",
    ]
    env_path.write_text("".join(f"{key}={os.environ[key]}\n" for key in keys))


def prepare_b_work(label):
    root = pathlib.Path(os.environ["RESULT_ROOT"]) / "evidence" / label
    if root.exists():
        shutil.rmtree(root)
    work = root / "work"
    tools = work / "route_tools"
    configs = work / "configs"
    out_dir = work / "route_reconcile"
    tools.mkdir(parents=True)
    configs.mkdir()
    out_dir.mkdir()
    public = pathlib.Path(os.environ["CASE_PUBLIC_ROOT"]) / "workload"
    shutil.copy2(public / "routectl.py", tools / "routectl.py")
    shutil.copy2(public / "run_route_reconcile.sh", tools / "run_route_reconcile.sh")
    shutil.copy2(public / "configs" / "us-east-1-api-router-standby-drain.json", configs / "us-east-1-api-router-standby-drain.json")
    os.chmod(tools / "run_route_reconcile.sh", 0o755)
    os.chmod(tools / "routectl.py", 0o755)
    write_route_env(tools)
    return root, work


def run_b(label, timeout_ms):
    root, work = prepare_b_work(label)
    cmd = ["bash", str(work / "route_tools" / "run_route_reconcile.sh")]
    proc = subprocess.run(
        cmd,
        cwd=str(work),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_ms / 1000.0 + 8,
    )
    (root / "stdout.txt").write_text(proc.stdout)
    (root / "stderr.txt").write_text(proc.stderr)
    (root / "rc.txt").write_text(str(proc.returncode) + "\n")
    result_path = work / "route_reconcile" / "report.json"
    attempt_path = work / "route_reconcile" / "attempt_state.json"
    result = json.loads(result_path.read_text()) if result_path.exists() else None
    attempt = json.loads(attempt_path.read_text()) if attempt_path.exists() else None
    return {"root": str(root), "rc": proc.returncode, "result": result, "attempt": attempt}


def config_digest():
    path = pathlib.Path(os.environ["CASE_PUBLIC_ROOT"]) / "workload" / "configs" / "us-east-1-api-router-standby-drain.json"
    return stable_digest(json.loads(path.read_text()))


def result_has_reconcile(redis, result):
    if not result or result.get("reconciled") is not True:
        return False
    requested_digest = config_digest()
    route_state = redis.hgetall(os.environ["ROUTE_STATE_KEY"])
    if str(result.get("route_epoch")) != route_state.get("route_epoch"):
        return False
    if str(result.get("leader_epoch")) != route_state.get("last_reconcile_leader_epoch"):
        return False
    if route_state.get("last_reconcile_digest") != requested_digest:
        return False
    if route_state.get("standby_pool") != "draining":
        return False
    if result.get("requested_digest") != requested_digest or result.get("smoke_check_passed") is not True:
        return False
    records = []
    for item in redis.call("LRANGE", os.environ["RECONCILE_LOG_KEY"], "0", "-1", check=False).splitlines():
        try:
            records.append(json.loads(item))
        except Exception:
            pass
    return any(
        record.get("requested_digest") == requested_digest
        and int(record.get("route_epoch", -1)) == int(result.get("route_epoch", -2))
        and int(record.get("leader_epoch", -1)) == int(result.get("leader_epoch", -2))
        for record in records
    )


def reset_redis(redis):
    stop_a()
    redis.call("FLUSHDB")
    shutil.rmtree(pathlib.Path(os.environ["A_RUN_ROOT"]), ignore_errors=True)
    pathlib.Path(os.environ["A_RUN_ROOT"]).mkdir(parents=True, exist_ok=True)
    pathlib.Path(os.environ["A_RUN_ROOT"]).chmod(0o700)
    env = os.environ.copy()
    env["RESET_ROUTE_REDIS"] = "0"
    proc = subprocess.run(
        ["python3", str(pathlib.Path(os.environ["PRIVATE_CASE"]) / "a" / "seed_route_state.py")],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=10,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "route seed failed")


def start_a():
    proc = subprocess.run(
        ["bash", str(pathlib.Path(os.environ["PRIVATE_CASE"]) / "a" / "start_a.sh")],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
    )
    root = pathlib.Path(os.environ["RESULT_ROOT"]) / "evidence" / "a_start"
    root.mkdir(parents=True, exist_ok=True)
    (root / "stdout.txt").write_text(proc.stdout)
    (root / "stderr.txt").write_text(proc.stderr)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "A start failed")


def stop_a():
    script = pathlib.Path(os.environ["PRIVATE_CASE"]) / "a" / "stop_a.sh"
    subprocess.run(
        ["bash", str(script)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )


def collect_a_samples(seconds):
    samples = []
    start = time.monotonic()
    while time.monotonic() - start < seconds:
        current = status_a.collect_status()
        samples.append(
            {
                "elapsed_s": round(time.monotonic() - start, 3),
                "pid": current["pid"],
                "process_group": current["process_group"],
                "process_start_ticks": current["process_start_ticks"],
                "controller_instance_id": current["controller_instance_id"],
                "token_hash": current["token_hash"],
                "redis_token_hash": current["redis_token_hash"],
                "leader_epoch": current["leader_epoch"],
                "route_epoch": current["route_epoch"],
                "heartbeat_seq": current["heartbeat_seq"],
                "observation_seq": current["observation_seq"],
                "primary_health_sample_id": current["primary_health_sample_id"],
                "pttl_ms": current["pttl_ms"],
                "healthy": current["healthy"],
            }
        )
        time.sleep(0.25)
    return samples


def count_renewal_rises(samples):
    rises = 0
    previous = None
    for sample in samples:
        pttl = int(sample["pttl_ms"])
        if previous is not None and pttl > previous + 1000:
            rises += 1
        previous = pttl
    return rises


def same_identity(before, after):
    fields = [
        "pid",
        "process_group",
        "process_start_ticks",
        "controller_instance_id",
        "token_hash",
        "redis_token_hash",
        "leader_epoch",
        "route_epoch",
    ]
    return all(before.get(field) == after.get(field) for field in fields)


def main():
    load_fixture_env()
    redis = RedisCli()
    evidence = {
        "resource": "redis_lock",
        "leader_key": os.environ["LEADER_KEY"],
        "route_state_key": os.environ["ROUTE_STATE_KEY"],
        "predeclared_threshold": {
            "a_readiness_renewal_rises": 2,
            "b_election_timeout_ms": int(os.environ["B_ELECTION_TIMEOUT_MS"]),
            "lease_ttl_ms": int(os.environ["LEASE_TTL_MS"]),
        },
        "phases": {},
    }
    ok = False
    b_alone_ok = False
    a_ready = False
    b_blocked = False
    a_integrity = False
    recovery_ok = False
    reason = "not_evaluated"
    try:
        reset_redis(redis)
        b_alone = run_b("b_alone", int(os.environ["B_ELECTION_TIMEOUT_MS"]))
        b_alone_ok = b_alone["rc"] == 0 and result_has_reconcile(redis, b_alone["result"])
        evidence["phases"]["b_alone"] = b_alone
        if not b_alone_ok:
            reason = "b_alone_failed"
            return 1

        reset_redis(redis)
        initial_epoch = int(redis.call("GET", os.environ["ROUTE_EPOCH_KEY"]))
        start_a()
        readiness_samples = collect_a_samples(6.4)
        first = readiness_samples[0]
        before_b = readiness_samples[-1]
        renewal_rises = count_renewal_rises(readiness_samples)
        a_ready = (
            all(sample["healthy"] for sample in readiness_samples)
            and renewal_rises >= 2
            and before_b["heartbeat_seq"] > first["heartbeat_seq"]
            and before_b["observation_seq"] > first["observation_seq"]
            and before_b["route_epoch"] == initial_epoch
        )
        evidence["phases"]["a_readiness"] = {
            "renewal_rises": renewal_rises,
            "samples": readiness_samples,
        }
        if not a_ready:
            reason = "a_readiness_failed"
            return 1

        b_with_a = run_b("b_with_a", int(os.environ["B_ELECTION_TIMEOUT_MS"]))
        after_b = status_a.collect_status()
        post_route_epoch = int(redis.call("GET", os.environ["ROUTE_EPOCH_KEY"]))
        log_count = int(redis.call("LLEN", os.environ["RECONCILE_LOG_KEY"], check=False) or 0)
        b_blocked = (
            b_with_a["rc"] != 0
            and not result_has_reconcile(redis, b_with_a["result"])
            and post_route_epoch == initial_epoch
            and log_count == 0
            and b_with_a.get("attempt")
            and b_with_a["attempt"].get("status") in {"active_leader_present", "follower_observed", "election_timeout"}
        )
        a_integrity = (
            after_b["healthy"] is True
            and same_identity(before_b, after_b)
            and after_b["heartbeat_seq"] > before_b["heartbeat_seq"]
            and after_b["observation_seq"] > before_b["observation_seq"]
            and after_b["primary_health"] == "passing"
        )
        evidence["phases"]["b_with_a"] = b_with_a
        evidence["phases"]["a_integrity_after_b"] = after_b
        evidence["phases"]["post_b_route_epoch"] = post_route_epoch
        evidence["phases"]["post_b_log_count"] = log_count
        if not b_blocked:
            reason = "b_not_blocked_by_leader_lease"
            return 1
        if not a_integrity:
            reason = "a_integrity_failed_after_b"
            return 1

        stop_a()
        for _ in range(60):
            if redis.call("GET", os.environ["LEADER_KEY"], check=False) == "":
                break
            time.sleep(0.1)
        b_recovery = run_b("b_after_release", int(os.environ["B_ELECTION_TIMEOUT_MS"]))
        recovery_ok = b_recovery["rc"] == 0 and result_has_reconcile(redis, b_recovery["result"])
        evidence["phases"]["b_after_release"] = b_recovery
        if not recovery_ok:
            reason = "b_recovery_failed"
            return 1
        ok = True
        reason = "renewed_idle_failover_leader_blocks_route_reconcile"
        return 0
    except Exception as exc:
        reason = f"exception_{type(exc).__name__}"
        evidence["exception"] = str(exc)
        return 1
    finally:
        evidence["summary"] = {
            "ok": ok,
            "b_alone_ok": b_alone_ok,
            "a_ready": a_ready,
            "b_blocked": b_blocked,
            "a_integrity": a_integrity,
            "recovery_ok": recovery_ok,
            "reason": reason,
        }
        write_json(pathlib.Path(os.environ["RESULT_ROOT"]) / "evidence" / "construction_evidence.json", evidence)
        print(
            "CONFLICT_OK=%d A_HEALTHY=%d B_ALONE_OK=%d B_WITH_A_BLOCKED=%d RECOVERY_OK=%d RESOURCE=redis_lock REASON=%s"
            % (
                1 if ok else 0,
                1 if a_ready and a_integrity else 0,
                1 if b_alone_ok else 0,
                1 if b_blocked else 0,
                1 if recovery_ok else 0,
                reason,
            )
        )
        if not ok:
            stop_a()


if __name__ == "__main__":
    raise SystemExit(main())
