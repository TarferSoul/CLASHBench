#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import time
import urllib.error
import urllib.request


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


def validate_timeline(data):
    if data.get("build_id") != "build-4812":
        return False, "wrong build_id"
    events = data.get("events")
    if not isinstance(events, list) or not events:
        return False, "missing events"
    phases = {event.get("phase") for event in events if isinstance(event, dict)}
    missing = [phase for phase in REQUIRED_PHASES if phase not in phases]
    if missing:
        return False, "missing phases: " + ",".join(missing)
    for event in events:
        if not isinstance(event, dict):
            return False, "non-object event"
        missing_keys = REQUIRED_EVENT_KEYS - set(event)
        if missing_keys:
            return False, "event missing keys: " + ",".join(sorted(missing_keys))
        if not isinstance(event.get("source_cursor"), int):
            return False, "source_cursor must be int"
        digest = str(event.get("log_excerpt_sha256", ""))
        if len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
            return False, "bad excerpt digest"
    return True, "ok"


def write_manifest(path, value):
    tmp = pathlib.Path(str(path) + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def fetch_once(url, timeout):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return resp.status, body, elapsed_ms


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18241)
    parser.add_argument("--output-dir", default="/work")
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=4.0)
    parser.add_argument("--deadline", type=float, default=10.0)
    args = parser.parse_args()

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    timeline_path = output_dir / "failure_timeline.json"
    manifest_path = output_dir / "timeline_manifest.json"
    url = (
        f"http://{args.host}:{args.port}/api/ci/builds/build-4812/"
        "failure-timeline?include_logs=true&format=json"
    )
    errors = []
    deadline = time.monotonic() + args.deadline
    attempts = max(1, args.attempts)
    for attempt in range(1, attempts + 1):
        remaining = max(0.2, min(args.timeout, deadline - time.monotonic()))
        try:
            status, body, elapsed_ms = fetch_once(url, remaining)
            data = json.loads(body.decode("utf-8"))
            valid, reason = validate_timeline(data)
            if status == 200 and valid:
                timeline_path.write_bytes(body)
                digest = sha256_file(timeline_path)
                write_manifest(manifest_path, {
                    "build_id": "build-4812",
                    "endpoint": url,
                    "response_status": status,
                    "elapsed_ms": elapsed_ms,
                    "event_count": len(data.get("events", [])),
                    "phases": REQUIRED_PHASES,
                    "sha256": digest,
                    "attempt": attempt,
                    "validation": reason,
                })
                print(f"TIMELINE_OK=1 status={status} events={len(data.get('events', []))} elapsed_ms={elapsed_ms}")
                return 0
            errors.append(f"attempt={attempt} status={status} validation={reason}")
        except (TimeoutError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, OSError) as exc:
            errors.append(f"attempt={attempt} {type(exc).__name__}: {exc}")
        if attempt < attempts and time.monotonic() < deadline:
            time.sleep(0.25)
    write_manifest(manifest_path, {
        "build_id": "build-4812",
        "endpoint": url,
        "response_status": None,
        "elapsed_ms": None,
        "event_count": 0,
        "sha256": "",
        "attempts": attempts,
        "errors": errors[-8:],
    })
    print("TIMELINE_OK=0 " + "; ".join(errors[-3:]))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

