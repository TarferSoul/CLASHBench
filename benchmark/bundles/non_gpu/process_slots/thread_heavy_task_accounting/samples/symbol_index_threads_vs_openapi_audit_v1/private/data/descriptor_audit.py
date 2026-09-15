#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import multiprocessing
import pathlib
import shutil
import sys
import time


def atomic_json(path, value):
    tmp = pathlib.Path(str(path) + f".tmp.{multiprocessing.current_process().pid}")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(path)


def validate(path):
    raw = path.read_bytes()
    value = json.loads(raw)
    errors = []
    if value.get("type") != "object": errors.append("type")
    if not isinstance(value.get("descriptor_id"), str) or not value["descriptor_id"]: errors.append("descriptor_id")
    if not isinstance(value.get("version"), str): errors.append("version")
    properties, required = value.get("properties"), value.get("required")
    if not isinstance(properties, dict): errors.append("properties"); properties = {}
    if not isinstance(required, list): errors.append("required"); required = []
    if any(item not in properties for item in required): errors.append("required_missing")
    return {"file": path.name, "descriptor_id": value.get("descriptor_id"), "valid": not errors, "errors": errors, "digest": hashlib.sha256(raw).hexdigest()}


def worker(index, paths, run_root, gate):
    atomic_json(run_root / f"ready-{index:03d}.json", {"worker": index, "pid": multiprocessing.current_process().pid})
    deadline = time.monotonic() + 15
    while not gate.exists():
        if time.monotonic() >= deadline: raise SystemExit(71)
        time.sleep(0.01)
    atomic_json(run_root / f"result-{index:03d}.json", {"worker": index, "pid": multiprocessing.current_process().pid, "descriptors": [validate(path) for path in paths]})


def stop_children(children):
    for child in children:
        if child.is_alive(): child.terminate()
    for child in children: child.join(timeout=3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--workers", required=True, type=int)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.workers < 1: raise SystemExit("--workers must be positive")
    source, output = pathlib.Path(args.input), pathlib.Path(args.output)
    paths = sorted(source.glob("*.json"))
    if len(paths) < args.workers or len(paths) % args.workers: raise SystemExit("descriptor count must be a nonzero multiple of worker count")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    attempt = output.parent / "descriptor-audit-attempt.json"
    attempt.unlink(missing_ok=True)
    run_root = output.parent / f".descriptor-audit-{__import__('os').getpid()}"
    shutil.rmtree(run_root, ignore_errors=True); run_root.mkdir()
    gate, children = run_root / "start", []
    ctx = multiprocessing.get_context("fork")
    assignments = [paths[index::args.workers] for index in range(args.workers)]
    try:
        for index in range(args.workers):
            child = ctx.Process(target=worker, args=(index, assignments[index], run_root, gate))
            try:
                child.start()
            except OSError as exc:
                stop_children(children)
                atomic_json(attempt, {"complete": False, "required_workers": args.workers, "launched_workers": len(children), "errno": exc.errno, "error": str(exc)})
                print(f"spawn_failed errno={exc.errno} launched={len(children)} required={args.workers} error={exc}", file=sys.stderr)
                return 75 if exc.errno in (errno.EAGAIN, errno.ENOMEM) else 70
            children.append(child)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if len(list(run_root.glob("ready-*.json"))) == args.workers: break
            if any(child.exitcode not in (None, 0) for child in children): stop_children(children); return 72
            time.sleep(0.02)
        else:
            stop_children(children); return 73
        gate.touch(); deadline = time.monotonic() + 20
        for child in children: child.join(timeout=max(0.0, deadline - time.monotonic()))
        if any(child.is_alive() or child.exitcode != 0 for child in children): stop_children(children); return 74
        records = [json.loads((run_root / f"result-{index:03d}.json").read_text()) for index in range(args.workers)]
        descriptors = sorted((item for record in records for item in record["descriptors"]), key=lambda item: item["descriptor_id"])
        aggregate = hashlib.sha256("".join(item["digest"] for item in descriptors).encode()).hexdigest()
        atomic_json(output, {"complete": True, "descriptor_count": len(descriptors), "worker_count": args.workers, "worker_slots": len(records), "worker_pids": [record["pid"] for record in records], "all_valid": all(item["valid"] for item in descriptors), "aggregate_digest": aggregate, "descriptors": descriptors})
        print(f"audit_complete descriptors={len(descriptors)} workers={args.workers} aggregate={aggregate}")
        return 0
    finally:
        stop_children(children); shutil.rmtree(run_root, ignore_errors=True)


if __name__ == "__main__": raise SystemExit(main())
