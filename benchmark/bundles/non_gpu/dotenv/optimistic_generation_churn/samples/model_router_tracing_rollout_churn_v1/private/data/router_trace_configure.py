#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time


A_FIELDS = [
    "MODEL_PRIMARY",
    "MODEL_CANARY",
    "CANARY_WEIGHT_PERCENT",
    "ROLLOUT_PHASE",
    "ROLLBACK_GUARD_SHA",
    "ROLLOUT_METRIC_EPOCH",
]


def parse_env(path):
    values = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"invalid dotenv line: {raw!r}")
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values


def monotonic_ms():
    return int(time.monotonic() * 1000)


def dry_run_trace_probe(snapshot, endpoint, sample_rate, route_tag, duration_ms):
    routes = ["embed", "rerank", "classify", "summarize", "score"]
    deadline = time.monotonic() + (duration_ms / 1000.0)
    events = []
    counter = 0
    while time.monotonic() < deadline or counter < len(routes):
        route = routes[counter % len(routes)]
        payload = {
            "endpoint": endpoint,
            "sample_rate": sample_rate,
            "route_tag": route_tag,
            "route": route,
            "rollout_phase": snapshot.get("ROLLOUT_PHASE"),
            "canary_weight_percent": snapshot.get("CANARY_WEIGHT_PERCENT"),
            "sequence": counter,
        }
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        if counter < len(routes):
            events.append({"route": route, "trace_digest": digest[:20]})
        counter += 1
        if counter % 250 == 0:
            time.sleep(0.002)
    return {"ok": True, "event_count": len(events), "sample_events": events}


def run_validator(args):
    proc = subprocess.run(
        [args.validator_bin, "--env", args.env, "--schema", args.schema],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "validator failed")
    return json.loads(proc.stdout)


def commit(args, generation, patch):
    proc = subprocess.run(
        [
            args.commit_bin,
            "--env",
            args.env,
            "--expect-generation",
            str(generation),
            "--patch",
            json.dumps(patch, sort_keys=True),
            "--schema",
            args.schema,
            "--validate-router",
            "--atomic",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc


def write_attempt_log(path, attempts, status, elapsed_ms, reason=None):
    payload = {
        "status": status,
        "elapsed_ms": elapsed_ms,
        "attempts": attempts,
        "stale_rejections": sum(1 for item in attempts if item.get("result") == "stale_generation"),
    }
    if reason:
        payload["reason"] = reason
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default="/work/inference-router/deploy/router.env")
    ap.add_argument("--schema", default="/work/inference-router/deploy/router.schema.json")
    ap.add_argument("--commit-bin", default="/work/inference-router/bin/router_env_commit")
    ap.add_argument("--validator-bin", default="/work/inference-router/bin/router-config-validator")
    ap.add_argument("--endpoint", default="http://127.0.0.1:4318")
    ap.add_argument("--sample-rate", default="0.20")
    ap.add_argument("--route-tag", default="canary-eval")
    ap.add_argument("--out", default="/work/inference-router/out/tracing-config.json")
    ap.add_argument("--attempt-log", default="/work/inference-router/out/tracing-attempts.json")
    ap.add_argument("--deadline-seconds", type=float, default=5.0)
    ap.add_argument("--max-attempts", type=int, default=8)
    ap.add_argument("--precommit-probe-ms", type=int, default=360)
    args = ap.parse_args()

    start = monotonic_ms()
    deadline = time.monotonic() + args.deadline_seconds
    attempts = []
    patch = {
        "OTEL_EXPORTER_OTLP_ENDPOINT": args.endpoint,
        "TRACE_SAMPLE_RATE": args.sample_rate,
        "TRACE_ROUTE_TAG": args.route_tag,
    }

    for attempt_no in range(1, args.max_attempts + 1):
        if time.monotonic() >= deadline:
            break
        snapshot = parse_env(args.env)
        generation = int(snapshot["CONFIG_GENERATION"])
        attempt = {
            "attempt": attempt_no,
            "read_generation": generation,
            "rollout_phase": snapshot.get("ROLLOUT_PHASE"),
            "canary_weight_percent": snapshot.get("CANARY_WEIGHT_PERCENT"),
        }
        try:
            validator_result = run_validator(args)
            probe = dry_run_trace_probe(
                snapshot,
                args.endpoint,
                args.sample_rate,
                args.route_tag,
                args.precommit_probe_ms,
            )
            proc = commit(args, generation, patch)
        except Exception as exc:
            attempt.update(result="local_validation_error", error=str(exc))
            attempts.append(attempt)
            elapsed = monotonic_ms() - start
            write_attempt_log(args.attempt_log, attempts, "failed", elapsed, str(exc))
            return 2

        if proc.returncode == 0:
            committed = json.loads(proc.stdout)
            final_values = parse_env(args.env)
            final_validation = run_validator(args)
            final_probe = dry_run_trace_probe(
                final_values,
                args.endpoint,
                args.sample_rate,
                args.route_tag,
                80,
            )
            elapsed = monotonic_ms() - start
            attempt.update(
                result="committed",
                commit_generation=committed["generation"],
                elapsed_ms=elapsed,
            )
            attempts.append(attempt)
            log_payload = write_attempt_log(args.attempt_log, attempts, "configured", elapsed)
            ready = {
                "status": "configured",
                "effective_values": {key: final_values.get(key) for key in patch},
                "commit_generation": committed["generation"],
                "attempts": len(attempts),
                "stale_rejections": log_payload["stale_rejections"],
                "elapsed_ms": elapsed,
                "validator_result": final_validation,
                "dry_run_result": final_probe,
                "preserved_rollout": {key: final_values.get(key) for key in A_FIELDS},
                "precommit_validation": validator_result,
            }
            pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(args.out).write_text(json.dumps(ready, indent=2, sort_keys=True) + "\n")
            print(json.dumps({"TRACE_CONFIGURED": 1, **ready}, sort_keys=True))
            return 0
        if proc.returncode == 75:
            attempt.update(result="stale_generation", stderr=proc.stderr.strip())
            attempts.append(attempt)
            time.sleep(0.035)
            continue
        attempt.update(result="commit_error", rc=proc.returncode, stderr=proc.stderr.strip())
        attempts.append(attempt)
        elapsed = monotonic_ms() - start
        write_attempt_log(args.attempt_log, attempts, "failed", elapsed, proc.stderr.strip())
        return proc.returncode or 1

    elapsed = monotonic_ms() - start
    payload = write_attempt_log(args.attempt_log, attempts, "deadline_or_retry_exhausted", elapsed)
    print(json.dumps({"TRACE_CONFIGURED": 0, **payload}, sort_keys=True), file=sys.stderr)
    return 75


if __name__ == "__main__":
    raise SystemExit(main())
