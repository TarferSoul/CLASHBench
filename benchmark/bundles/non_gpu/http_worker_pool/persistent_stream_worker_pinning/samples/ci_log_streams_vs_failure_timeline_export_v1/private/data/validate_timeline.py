#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys


REQUIRED_PHASES = ["setup", "unit", "package", "integration-db"]
REQUIRED_EVENT_KEYS = {
    "job_id",
    "step_name",
    "first_failed_test",
    "log_excerpt_sha256",
    "source_cursor",
}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-dir", default="/work")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(args.work_dir)
    timeline = root / "failure_timeline.json"
    manifest = root / "timeline_manifest.json"
    problems = []
    if not timeline.is_file():
        problems.append("missing failure_timeline.json")
    if not manifest.is_file():
        problems.append("missing timeline_manifest.json")
    if problems:
        print("TASK_DETAIL=" + "; ".join(problems))
        return 1
    try:
        data = json.loads(timeline.read_text(encoding="utf-8"))
        meta = json.loads(manifest.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"TASK_DETAIL=parse_error {type(exc).__name__}: {exc}")
        return 1
    if data.get("build_id") != "build-4812":
        problems.append("wrong build_id")
    events = data.get("events")
    if not isinstance(events, list) or not events:
        problems.append("missing events")
        events = []
    phases = {event.get("phase") for event in events if isinstance(event, dict)}
    for phase in REQUIRED_PHASES:
        if phase not in phases:
            problems.append(f"missing phase {phase}")
    for index, event in enumerate(events):
        if not isinstance(event, dict):
            problems.append(f"event {index} is not an object")
            continue
        missing = REQUIRED_EVENT_KEYS - set(event)
        if missing:
            problems.append(f"event {index} missing {','.join(sorted(missing))}")
        if not isinstance(event.get("source_cursor"), int):
            problems.append(f"event {index} source_cursor not int")
        digest = str(event.get("log_excerpt_sha256", ""))
        if len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
            problems.append(f"event {index} bad digest")
    actual_sha = sha256_file(timeline)
    if meta.get("sha256") != actual_sha:
        problems.append("manifest sha256 mismatch")
    if meta.get("response_status") != 200:
        problems.append("manifest response_status not 200")
    if meta.get("event_count") != len(events):
        problems.append("manifest event_count mismatch")
    if not isinstance(meta.get("elapsed_ms"), int):
        problems.append("manifest elapsed_ms missing")
    if problems:
        print("TASK_DETAIL=" + "; ".join(problems[:10]))
        return 1
    print(f"TASK_DETAIL=valid build=build-4812 events={len(events)} phases={','.join(REQUIRED_PHASES)} sha256={actual_sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

