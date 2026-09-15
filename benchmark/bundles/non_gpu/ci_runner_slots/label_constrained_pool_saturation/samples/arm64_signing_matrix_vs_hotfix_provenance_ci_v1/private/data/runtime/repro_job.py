#!/usr/bin/env python3
"""Finite ARM64 reproducibility shard with independently measurable progress."""

import argparse
import hashlib
import json
import os
import pathlib
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--steps", type=int, required=True)
    parser.add_argument("--interval", type=float, required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--artifact", required=True)
    args = parser.parse_args()
    progress = pathlib.Path(args.progress)
    artifact = pathlib.Path(args.artifact)
    progress.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    for step in range(1, args.steps + 1):
        digest.update(f"arm64-repro-shard={args.shard}:step={step}:abi=v13\n".encode())
        progress.write_text(json.dumps({
            "workflow_id": os.environ["CI_WORKFLOW_ID"], "shard": args.shard,
            "state": "running", "completed_steps": step, "total_steps": args.steps,
            "executor_id": os.environ["CI_EXECUTOR_ID"], "job_id": os.environ["CI_JOB_ID"],
            "lease_id": os.environ["CI_LEASE_ID"], "catalog_sha256": digest.hexdigest(),
            "updated_at": time.time(),
        }, sort_keys=True) + "\n")
        time.sleep(args.interval)
    artifact.write_text(json.dumps({
        "complete": True, "workflow_id": os.environ["CI_WORKFLOW_ID"], "shard": args.shard,
        "executor_id": os.environ["CI_EXECUTOR_ID"], "job_id": os.environ["CI_JOB_ID"],
        "catalog_sha256": digest.hexdigest(), "objects_verified": args.steps,
    }, sort_keys=True) + "\n")
    progress.write_text(json.dumps({
        "workflow_id": os.environ["CI_WORKFLOW_ID"], "shard": args.shard,
        "state": "completed", "completed_steps": args.steps, "total_steps": args.steps,
        "executor_id": os.environ["CI_EXECUTOR_ID"], "job_id": os.environ["CI_JOB_ID"],
        "lease_id": os.environ["CI_LEASE_ID"], "artifact": str(artifact),
        "updated_at": time.time(),
    }, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
