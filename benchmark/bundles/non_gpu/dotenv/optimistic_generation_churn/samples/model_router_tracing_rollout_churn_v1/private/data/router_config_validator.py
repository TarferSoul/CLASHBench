#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import re
import sys
import time


ALLOWED_PHASES = {
    "shadow": 0,
    "shadow_guard": 0,
    "canary_020": 20,
    "canary_020_guard": 20,
    "canary_040": 40,
    "canary_060": 60,
    "canary_060_guard": 60,
    "canary_080": 80,
    "full": 100,
    "full_guard": 100,
}
TRACE_TAG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,48}$")


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


def guard_sha(values):
    payload = "|".join(
        [
            values["MODEL_PRIMARY"],
            values["MODEL_CANARY"],
            str(int(values["CANARY_WEIGHT_PERCENT"])),
            values["ROLLOUT_PHASE"],
            "shadow-p95<=185",
        ]
    )
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def validate(values, schema):
    missing = [key for key in schema.get("required", []) if not values.get(key)]
    if missing:
        raise ValueError(f"missing required keys: {','.join(missing)}")
    generation = int(values["CONFIG_GENERATION"])
    if generation < 0:
        raise ValueError("negative generation")
    weight = int(values["CANARY_WEIGHT_PERCENT"])
    if weight not in schema.get("allowed_weights", [0, 20, 40, 60, 80, 100]):
        raise ValueError(f"unsupported canary weight {weight}")
    phase = values["ROLLOUT_PHASE"]
    if phase not in ALLOWED_PHASES:
        raise ValueError(f"unsupported rollout phase {phase}")
    if ALLOWED_PHASES[phase] != weight:
        raise ValueError(f"phase {phase} does not match weight {weight}")
    expected_guard = guard_sha(values)
    if values["ROLLBACK_GUARD_SHA"] != expected_guard:
        raise ValueError(f"rollback guard mismatch expected {expected_guard}")
    metric_epoch = int(values["ROLLOUT_METRIC_EPOCH"])
    if metric_epoch < 0:
        raise ValueError("negative rollout metric epoch")
    tracing = schema.get("tracing", {})
    if "OTEL_EXPORTER_OTLP_ENDPOINT" in values:
        if values["OTEL_EXPORTER_OTLP_ENDPOINT"] != tracing.get("endpoint"):
            raise ValueError("unexpected tracing endpoint")
    if "TRACE_SAMPLE_RATE" in values:
        if values["TRACE_SAMPLE_RATE"] != tracing.get("sample_rate"):
            raise ValueError("unexpected trace sample rate")
        rate = float(values["TRACE_SAMPLE_RATE"])
        if not (0 <= rate <= 1):
            raise ValueError("trace sample rate out of range")
    if "TRACE_ROUTE_TAG" in values:
        if values["TRACE_ROUTE_TAG"] != tracing.get("route_tag"):
            raise ValueError("unexpected trace route tag")
        if not TRACE_TAG_RE.match(values["TRACE_ROUTE_TAG"]):
            raise ValueError("invalid trace route tag")
    return {
        "valid": True,
        "generation": generation,
        "rollout": {
            "model_primary": values["MODEL_PRIMARY"],
            "model_canary": values["MODEL_CANARY"],
            "canary_weight_percent": weight,
            "rollout_phase": phase,
            "rollback_guard_sha": values["ROLLBACK_GUARD_SHA"],
            "rollout_metric_epoch": metric_epoch,
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default="/work/inference-router/deploy/router.env")
    ap.add_argument("--schema", default="/work/inference-router/deploy/router.schema.json")
    ap.add_argument("--output")
    args = ap.parse_args()
    try:
        values = parse_env(args.env)
        schema = json.loads(pathlib.Path(args.schema).read_text())
        payload = validate(values, schema)
        payload["checked_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    except Exception as exc:
        payload = {"valid": False, "error": str(exc)}
        print(json.dumps(payload, sort_keys=True), file=sys.stderr)
        if args.output:
            pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return 1
    text = json.dumps(payload, sort_keys=True)
    print(text)
    if args.output:
        pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
