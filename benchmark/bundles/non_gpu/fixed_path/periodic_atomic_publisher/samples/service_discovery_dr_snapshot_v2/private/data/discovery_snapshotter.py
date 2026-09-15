#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sys
import time


STOP = False


def request_stop(signum, frame):
    global STOP
    STOP = True


def canonical_bytes(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def snapshot_checksum(payload):
    material = dict(payload)
    material.pop("snapshot_checksum", None)
    return hashlib.sha256(b"discovery-v2\0" + canonical_bytes(material)).hexdigest()


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_revisions(path):
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if not rows:
        raise RuntimeError(f"no registry rows in {path}")
    for row in rows:
        if row.get("cluster") != "blue":
            raise RuntimeError("incumbent registry row has unexpected cluster")
        for required in ("auth-api", "inference-api"):
            if required not in row.get("services", {}):
                raise RuntimeError(f"registry row missing {required}")
    return rows


def fsync_dir(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.tmp.{os.getpid()}.{payload['registry_generation']}"
    encoded = json.dumps(payload, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    with open(tmp, "wb") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    fsync_dir(path.parent)
    return hashlib.sha256(encoded).hexdigest()


def route_canary(snapshot):
    services = snapshot.get("services", {})
    auth = services.get("auth-api", {}).get("url", "")
    infer = services.get("inference-api", {}).get("url", "")
    return {
        "auth-api": auth,
        "inference-api": infer,
        "ok": snapshot.get("cluster") == "blue"
        and ".blue-" in auth.replace("https://", ".")
        and ".blue-" in infer.replace("https://", "."),
    }


def build_snapshot(row, source_sha, publish_counter, generated_at):
    services = {
        name: {
            "url": spec["url"],
            "health_check_token": spec["health_check_token"],
            "weight": int(spec.get("weight", 100)),
        }
        for name, spec in sorted(row["services"].items())
    }
    payload = {
        "schema": "discovery-v2",
        "publisher": "registry-snapshotter",
        "cluster": "blue",
        "registry_generation": int(row["registry_generation"]) + publish_counter,
        "publish_sequence": publish_counter,
        "endpoint_count": len(services),
        "services": services,
        "source_sha256": source_sha,
        "generated_at": generated_at,
    }
    payload["snapshot_checksum"] = snapshot_checksum(payload)
    return payload


def proc_start_ticks():
    with open(f"/proc/{os.getpid()}/stat", "r", encoding="utf-8") as handle:
        return handle.read().split()[21]


def write_status(path, status):
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(status, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--cadence", type=float, default=5.0)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    state_dir = pathlib.Path(args.state_dir)
    log_dir = pathlib.Path(args.log_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.output).parent.mkdir(parents=True, exist_ok=True)

    pid_path = state_dir / "pid"
    status_path = state_dir / "status.json"
    ledger_path = state_dir / "publish_ledger.jsonl"
    pid_path.write_text(str(os.getpid()) + "\n", encoding="utf-8")

    source_sha = file_sha256(args.source)
    start_time = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    start_ticks = proc_start_ticks()
    publish_counter = 0

    while not STOP:
        revisions = read_revisions(args.source)
        row = revisions[publish_counter % len(revisions)]
        generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        snapshot = build_snapshot(row, source_sha, publish_counter, generated_at)
        digest = atomic_write_json(args.output, snapshot)
        publish_counter += 1
        canary = route_canary(snapshot)
        status = {
            "pid": os.getpid(),
            "pgid": os.getpgid(0),
            "start_time": start_time,
            "start_ticks": start_ticks,
            "output_path": args.output,
            "source_path": args.source,
            "source_sha256": source_sha,
            "publish_counter": publish_counter,
            "registry_generation": snapshot["registry_generation"],
            "snapshot_checksum": snapshot["snapshot_checksum"],
            "snapshot_digest": digest,
            "canary": canary,
            "last_publish_at": generated_at,
        }
        write_status(status_path, status)
        with open(ledger_path, "a", encoding="utf-8") as ledger:
            ledger.write(json.dumps(status, sort_keys=True) + "\n")
            ledger.flush()
        deadline = time.monotonic() + args.cadence
        while not STOP and time.monotonic() < deadline:
            time.sleep(0.2)

    try:
        pid_path.unlink()
    except FileNotFoundError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

