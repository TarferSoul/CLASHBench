#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import fcntl


ORDER = [
    "CONFIG_GENERATION",
    "MODEL_PRIMARY",
    "MODEL_CANARY",
    "CANARY_WEIGHT_PERCENT",
    "ROLLOUT_PHASE",
    "ROLLBACK_GUARD_SHA",
    "ROLLOUT_METRIC_EPOCH",
    "ROUTER_POLICY_SHA",
    "ROUTER_REGION",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "TRACE_SAMPLE_RATE",
    "TRACE_ROUTE_TAG",
]
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
    source_order = []
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"invalid dotenv line: {raw!r}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not re.match(r"^[A-Z0-9_]+$", key):
            raise ValueError(f"invalid key: {key!r}")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key not in source_order:
            source_order.append(key)
        values[key] = value
    return values, source_order


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
    required = schema.get("required", ORDER[:8])
    missing = [key for key in required if key not in values or values[key] == ""]
    if missing:
        raise ValueError(f"missing required keys: {','.join(missing)}")
    try:
        generation = int(values["CONFIG_GENERATION"])
    except Exception as exc:
        raise ValueError("CONFIG_GENERATION must be an integer") from exc
    if generation < 0:
        raise ValueError("CONFIG_GENERATION must be non-negative")
    try:
        weight = int(values["CANARY_WEIGHT_PERCENT"])
    except Exception as exc:
        raise ValueError("CANARY_WEIGHT_PERCENT must be an integer") from exc
    if weight not in set(schema.get("allowed_weights", [0, 20, 40, 60, 80, 100])):
        raise ValueError(f"unsupported canary weight: {weight}")
    phase = values["ROLLOUT_PHASE"]
    if phase not in ALLOWED_PHASES:
        raise ValueError(f"unsupported rollout phase: {phase}")
    if ALLOWED_PHASES[phase] != weight:
        raise ValueError(f"phase {phase} does not match canary weight {weight}")
    expected_guard = guard_sha(values)
    if values["ROLLBACK_GUARD_SHA"] != expected_guard:
        raise ValueError(
            f"ROLLBACK_GUARD_SHA mismatch: got {values['ROLLBACK_GUARD_SHA']} expected {expected_guard}"
        )
    if int(values["ROLLOUT_METRIC_EPOCH"]) < 0:
        raise ValueError("ROLLOUT_METRIC_EPOCH must be non-negative")
    if "OTEL_EXPORTER_OTLP_ENDPOINT" in values:
        expected = schema.get("tracing", {}).get("endpoint", "http://127.0.0.1:4318")
        if values["OTEL_EXPORTER_OTLP_ENDPOINT"] != expected:
            raise ValueError("OTEL_EXPORTER_OTLP_ENDPOINT is not the configured local collector")
    if "TRACE_SAMPLE_RATE" in values:
        try:
            sample_rate = float(values["TRACE_SAMPLE_RATE"])
        except Exception as exc:
            raise ValueError("TRACE_SAMPLE_RATE must be numeric") from exc
        if not (0.0 <= sample_rate <= 1.0):
            raise ValueError("TRACE_SAMPLE_RATE must be between 0 and 1")
    if "TRACE_ROUTE_TAG" in values and not TRACE_TAG_RE.match(values["TRACE_ROUTE_TAG"]):
        raise ValueError("TRACE_ROUTE_TAG must be a short lowercase route tag")
    return True


def render(values, source_order):
    keys = []
    for key in ORDER + source_order + sorted(values):
        if key in values and key not in keys:
            keys.append(key)
    return "".join(f"{key}={values[key]}\n" for key in keys)


def load_patch(args):
    if args.patch and args.patch_file:
        raise SystemExit("use --patch or --patch-file, not both")
    if args.patch_file:
        return json.loads(pathlib.Path(args.patch_file).read_text())
    if args.patch:
        return json.loads(args.patch)
    raise SystemExit("missing --patch or --patch-file")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--expect-generation", required=True, type=int)
    ap.add_argument("--patch")
    ap.add_argument("--patch-file")
    ap.add_argument("--schema", default="/work/inference-router/deploy/router.schema.json")
    ap.add_argument("--validate-router", action="store_true")
    ap.add_argument("--atomic", action="store_true")
    ap.add_argument("--output-json")
    args = ap.parse_args()

    env_path = pathlib.Path(args.env)
    env_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = pathlib.Path(str(env_path) + ".lock")
    patch = load_patch(args)
    schema = json.loads(pathlib.Path(args.schema).read_text()) if args.schema else {}

    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o666)
    os.chmod(lock_path, 0o666)
    with os.fdopen(lock_fd, "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        values, source_order = parse_env(env_path)
        current_generation = int(values.get("CONFIG_GENERATION", "-1"))
        if current_generation != args.expect_generation:
            payload = {
                "status": "stale_generation",
                "expected_generation": args.expect_generation,
                "current_generation": current_generation,
            }
            text = json.dumps(payload, sort_keys=True)
            print(text, file=sys.stderr)
            if args.output_json:
                pathlib.Path(args.output_json).write_text(text + "\n")
            return 75
        merged = dict(values)
        for key, value in patch.items():
            if key == "CONFIG_GENERATION":
                continue
            if value is None:
                merged.pop(key, None)
            else:
                merged[key] = str(value)
        merged["CONFIG_GENERATION"] = str(current_generation + 1)
        if args.validate_router:
            validate(merged, schema)

        rendered = render(merged, source_order)
        fd, tmp_name = tempfile.mkstemp(prefix=".router-env-", dir=str(env_path.parent), text=True)
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(rendered)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp_name, 0o664)
            if args.atomic:
                os.replace(tmp_name, env_path)
            else:
                pathlib.Path(env_path).write_text(rendered)
                os.unlink(tmp_name)
            directory_fd = os.open(env_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        payload = {
            "status": "committed",
            "previous_generation": current_generation,
            "generation": current_generation + 1,
            "updated_keys": sorted(key for key in patch if key != "CONFIG_GENERATION"),
        }
        text = json.dumps(payload, sort_keys=True)
        print(text)
        if args.output_json:
            pathlib.Path(args.output_json).write_text(text + "\n")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
