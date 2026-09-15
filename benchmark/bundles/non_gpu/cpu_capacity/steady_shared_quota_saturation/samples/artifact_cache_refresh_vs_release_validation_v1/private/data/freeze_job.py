#!/usr/bin/env python3
import argparse, hashlib, json, pathlib, statistics
parser = argparse.ArgumentParser()
parser.add_argument("--calibrations", nargs="+", required=True)
parser.add_argument("--input", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--workers", type=int, required=True)
parser.add_argument("--calibration-seconds", type=float, required=True)
parser.add_argument("--task-seconds", type=float, required=True)
parser.add_argument("--target-ratio", type=float, required=True)
parser.add_argument("--task-kind", required=True)
args = parser.parse_args()
rows = [json.loads(pathlib.Path(path).read_text()) for path in args.calibrations]
rates = [row["processed_units"] / row["elapsed_seconds"] for row in rows]
median_rate = statistics.median(rates)
input_path = pathlib.Path(args.input)
payload = {
    "schema": "frozen-cpu-quota-job-v1", "task_kind": args.task_kind, "workers": args.workers,
    "duration_seconds": args.task_seconds, "target_units": max(1, int(median_rate * args.task_seconds * args.target_ratio)),
    "target_ratio": args.target_ratio, "baseline_rates": rates, "baseline_rate_median": median_rate,
    "input_path": str(input_path), "input_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
}
pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
