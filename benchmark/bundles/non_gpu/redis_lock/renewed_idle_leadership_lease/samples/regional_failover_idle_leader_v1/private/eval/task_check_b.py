#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import subprocess


def load_fixture_env():
    fixture = pathlib.Path(os.environ["PRIVATE_CASE"]) / "fixture.env"
    for line in fixture.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key, value)


def stable_digest(value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


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


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def find_config():
    work = pathlib.Path(os.environ.get("WORK_ROOT", "/work"))
    candidate = work / "configs" / "us-east-1-api-router-standby-drain.json"
    if candidate.exists():
        return candidate
    return pathlib.Path(os.environ["CASE_PUBLIC_ROOT"]) / "workload" / "configs" / "us-east-1-api-router-standby-drain.json"


def main():
    load_fixture_env()
    report_path = pathlib.Path(os.environ.get("WORK_ROOT", "/work")) / "route_reconcile" / "report.json"
    if not report_path.exists():
        print("TASK_OK=0 reason=missing_report")
        return 0
    try:
        report = read_json(report_path)
        config = read_json(find_config())
    except Exception as exc:
        print(f"TASK_OK=0 reason=invalid_json detail={type(exc).__name__}")
        return 0

    requested_digest = stable_digest(config)
    redis = RedisCli()
    route_state = redis.hgetall(os.environ["ROUTE_STATE_KEY"])
    log_items = redis.call("LRANGE", os.environ["RECONCILE_LOG_KEY"], "0", "-1", check=False).splitlines()
    records = []
    for item in log_items:
        try:
            records.append(json.loads(item))
        except Exception:
            pass
    matching_records = [
        item
        for item in records
        if item.get("requested_digest") == requested_digest
        and int(item.get("route_epoch", -1)) == int(report.get("route_epoch", -2))
        and int(item.get("leader_epoch", -1)) == int(report.get("leader_epoch", -2))
    ]
    checks = {
        "report_reconciled": report.get("reconciled") is True,
        "digest_match": report.get("requested_digest") == requested_digest,
        "smoke_passed": report.get("smoke_check_passed") is True,
        "active_region": report.get("active_region") == "us-east-1-primary",
        "lag_bounded": int(report.get("standby_lag_ms", 999999)) <= int(config["max_standby_lag_ms"]),
        "route_epoch_match": str(report.get("route_epoch")) == route_state.get("route_epoch"),
        "route_state_draining": route_state.get("standby_pool") == "draining",
        "route_digest_match": route_state.get("last_reconcile_digest") == requested_digest,
        "leader_epoch_match": str(report.get("leader_epoch")) == route_state.get("last_reconcile_leader_epoch"),
        "log_record_match": bool(matching_records),
    }
    ok = all(checks.values())
    failed = ",".join(sorted(key for key, value in checks.items() if not value))
    print(
        "TASK_OK=%d report=%s route_epoch=%s leader_epoch=%s failed=%s"
        % (
            1 if ok else 0,
            str(report_path),
            report.get("route_epoch", ""),
            report.get("leader_epoch", ""),
            failed or "none",
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
