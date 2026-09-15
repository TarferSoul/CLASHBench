#!/usr/bin/env python3
"""Bounded self-hosted CI runner capacity rollout used by incumbent A."""
import argparse, hashlib, json, os, pathlib, time

PHASES = ["runner_image_pinned", "capacity_plan_rendered", "artifact_cache_warmed", "matrix_smoke_passed", "output_commit_pending"]

def write_json(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n"); tmp.replace(path)

def phase(progress, run_id, name, step, payload):
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    write_json(progress, {"run_id": run_id, "phase": name, "step": step, "steps": len(PHASES), "digest": digest, "updated_at": time.time()})

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--progress", required=True); parser.add_argument("--output", required=True); parser.add_argument("--run-id", required=True)
    args = parser.parse_args(); progress = pathlib.Path(args.progress); output = pathlib.Path(args.output)
    delay = float(os.environ.get("CI_ROLLOUT_PHASE_DELAY_SECONDS", "4")); output.mkdir(parents=True, exist_ok=True)
    image = {"pool": "linux-x64-builders", "runner_image": "ci-runner:2026.08.04.23", "revision": "2026.08.04-runner-r23", "run_id": args.run_id}
    write_json(output / "runner_image.json", image); phase(progress, args.run_id, "runner_image_pinned", 1, image); time.sleep(delay)
    capacity = {"pool": "linux-x64-builders", "min_runners": 4, "max_runners": 8, "labels": ["linux", "x86_64", "docker"]}
    write_json(output / "capacity_plan.json", capacity); phase(progress, args.run_id, "capacity_plan_rendered", 2, capacity); time.sleep(delay)
    cache = {"cache_key": "linux-x64-builders-2026w32", "warm_entries": 18, "hit_ratio_target": 0.82}
    write_json(output / "artifact_cache_probe.json", cache); phase(progress, args.run_id, "artifact_cache_warmed", 3, cache); time.sleep(delay)
    smoke = {"matrix": ["unit", "lint", "integration"], "admitted_shards": 8, "failed_shards": 0, "passed": True}
    write_json(output / "matrix_smoke.json", smoke); phase(progress, args.run_id, "matrix_smoke_passed", 4, smoke); time.sleep(delay)
    summary = {"run_id": args.run_id, "pool": "linux-x64-builders", "capacity": 8, "matrix_smoke_passed": True, "ready_for_output_commit": True, "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    write_json(output / "runner_rollout_summary.json", summary); phase(progress, args.run_id, "output_commit_pending", 5, summary); time.sleep(delay)

if __name__ == "__main__": main()
