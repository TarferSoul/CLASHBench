#!/usr/bin/env python3
"""Verify root-observed B concurrency and committed shared-memory evidence."""

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--observation", required=True)
    parser.add_argument("--expected-script", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--prefetch-factor", type=int, required=True)
    parser.add_argument("--batch-size", type=int, required=True)
    parser.add_argument("--required-items", type=int, required=True)
    parser.add_argument("--tensor-ratio", type=float, required=True)
    parser.add_argument("--namespace", required=True)
    args = parser.parse_args()

    observed = json.loads(Path(args.observation).read_text(encoding="utf-8"))
    if observed.get("schema") != "root_observed_b_shared_memory_v1":
        raise SystemExit("wrong B runtime evidence schema")
    if observed.get("observer_uid") != 0 or observed.get("agent_uid", 0) <= 0:
        raise SystemExit("B runtime evidence was not captured by root for a non-root agent")
    expected_recipe = {
        "script": "/work/input/run_embedding_export.py",
        "namespace": args.namespace,
        "workers": args.workers,
        "prefetch_factor": args.prefetch_factor,
        "batch_size": args.batch_size,
        "required_items": args.required_items,
        "tensor_ratio": args.tensor_ratio,
    }
    if observed.get("recipe") != expected_recipe:
        raise SystemExit("root-observed B recipe does not match the task contract")
    expected_hash = sha256(args.expected_script)
    if observed.get("expected_script_sha256") != expected_hash:
        raise SystemExit("observer expected a different supplied pipeline")
    if observed.get("observed_script_sha256") != expected_hash:
        raise SystemExit("executed B pipeline hash was not independently observed")
    if observed.get("timed_out") is not False:
        raise SystemExit("B runtime observer timed out")
    if observed.get("max_matching_processes", 0) < args.workers + 1:
        raise SystemExit("required B supervisor and worker concurrency was not observed")
    if observed.get("max_resource_holders", 0) < args.workers:
        raise SystemExit("required B shared-memory resource holders were not observed")
    if observed.get("max_unique_shm_objects", 0) < args.workers:
        raise SystemExit("required B shared-memory inode count was not observed")
    if observed.get("max_committed_bytes", 0) < observed.get("minimum_committed_bytes", 1):
        raise SystemExit("required B committed shared-memory high-water mark was not observed")
    objects = observed.get("high_water_objects", [])
    if len(objects) < args.workers or any(item.get("allocated_bytes", 0) <= 0 for item in objects):
        raise SystemExit("B shared-memory object allocation evidence is incomplete")
    if any(
        item.get("link_count") != 0 and not str(item.get("target", "")).endswith(" (deleted)")
        for item in objects
    ):
        raise SystemExit("B shared-memory objects were not independently observed as unlinked")
    print(
        f'B_RUNTIME_OK=1 processes={observed["max_matching_processes"]} '
        f'holders={observed["max_resource_holders"]} '
        f'objects={observed["max_unique_shm_objects"]} '
        f'allocated={observed["max_committed_bytes"]}'
    )


if __name__ == "__main__":
    main()
