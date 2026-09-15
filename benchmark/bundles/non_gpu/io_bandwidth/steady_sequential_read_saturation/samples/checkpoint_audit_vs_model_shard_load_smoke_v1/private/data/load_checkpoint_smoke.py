#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys
import time

from artifact_io import atomic_json, direct_sample_read, diskstats_delta, diskstats_snapshot, io_pressure, now_ms, parse_safetensors_header, read_proc_io, stat_identity, tensor_prefix_digest


def load_checkpoint(args):
    checkpoint = pathlib.Path(args.checkpoint)
    manifest_path = pathlib.Path(args.manifest)
    out = pathlib.Path(args.out)
    manifest = json.loads(manifest_path.read_text())
    start = time.monotonic()
    proc_before = read_proc_io()
    disk_before = diskstats_snapshot()
    pressure_before = io_pressure()
    output_digest = hashlib.sha256()
    deadline_ms = int(args.deadline_ms)
    block_bytes = int(args.block_bytes)
    sample_bytes = int(args.sample_bytes)
    shards_loaded = 0
    bytes_read = 0
    shard_reports = []
    validation_status = "ok"
    direct_ok = True

    for shard in manifest["shards"]:
        if deadline_ms > 0 and now_ms(start) > deadline_ms:
            validation_status = "deadline_missed"
            break
        path = pathlib.Path(shard["path"])
        if not path.is_absolute():
            path = checkpoint / path
        try:
            parsed = parse_safetensors_header(path)
            if len(parsed["tensors"]) != int(shard["tensor_count"]):
                validation_status = "tensor_count_mismatch"
                break
            read = direct_sample_read(path, block_bytes, sample_bytes, require_direct=not args.allow_buffered)
            direct_ok = direct_ok and bool(read["direct"])
            if read["sample_sha256"] != shard["block_sample_sha256"]:
                validation_status = "shard_digest_mismatch"
                break
            selected_ok = True
            for name, expected in shard["tensor_prefix_sha256"].items():
                tensor = parsed["tensors"].get(name)
                if not tensor:
                    selected_ok = False
                    break
                actual = tensor_prefix_digest(path, parsed["data_start"], tensor["data_offsets"][0], min(sample_bytes, 4096))
                if actual != expected:
                    selected_ok = False
                    break
            if not selected_ok:
                validation_status = "tensor_digest_mismatch"
                break
            output_digest.update(shard["shard_id"].encode())
            output_digest.update(read["sample_sha256"].encode())
            shards_loaded += 1
            bytes_read += int(read["bytes"])
            shard_reports.append(
                {
                    "shard_id": shard["shard_id"],
                    "bytes": read["bytes"],
                    "read_mode": read["read_mode"],
                    "process_read_bytes_delta": read["process_read_bytes_delta"],
                    "tensor_count": len(parsed["tensors"]),
                    "selected_tensor_digests_ok": True,
                }
            )
        except Exception as exc:
            validation_status = f"load_error:{type(exc).__name__}"
            shard_reports.append({"shard_id": shard.get("shard_id", ""), "error": str(exc)})
            break
        if deadline_ms > 0 and now_ms(start) > deadline_ms and shards_loaded < int(manifest["shard_count"]):
            validation_status = "deadline_missed"
            break

    complete = (
        validation_status == "ok"
        and shards_loaded == int(manifest["shard_count"])
        and bytes_read == int(manifest["total_bytes"])
        and direct_ok
    )
    elapsed_ms = now_ms(start)
    if complete and deadline_ms > 0 and elapsed_ms > deadline_ms:
        validation_status = "deadline_missed"
        complete = False
    elif not complete and validation_status == "ok":
        validation_status = "incomplete_checkpoint_load"

    smoke_value = ""
    if shards_loaded:
        smoke = hashlib.sha256()
        smoke.update(manifest["checkpoint_id"].encode())
        smoke.update(output_digest.hexdigest().encode())
        smoke.update(str(shards_loaded).encode())
        smoke_value = smoke.hexdigest()

    proc_after = read_proc_io()
    disk_after = diskstats_snapshot()
    report = {
        "checkpoint_id": manifest["checkpoint_id"],
        "manifest": str(manifest_path),
        "shards_loaded": shards_loaded,
        "expected_shards": manifest["shard_count"],
        "bytes_read": bytes_read,
        "expected_bytes": manifest["total_bytes"],
        "validation_status": validation_status,
        "direct_read": direct_ok,
        "output_digest": output_digest.hexdigest() if complete else "",
        "smoke_digest": smoke_value,
        "elapsed_ms": elapsed_ms,
        "deadline_ms": deadline_ms,
        "process_read_bytes_delta": proc_after.get("read_bytes", 0) - proc_before.get("read_bytes", 0),
        "process_rchar_delta": proc_after.get("rchar", 0) - proc_before.get("rchar", 0),
        "checkpoint_identity": stat_identity(checkpoint),
        "diskstats_delta": diskstats_delta(disk_before, disk_after),
        "io_pressure_before": pressure_before,
        "io_pressure_after": io_pressure(),
        "shards": shard_reports,
    }
    atomic_json(out, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if complete else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--deadline-ms", type=int, required=True)
    parser.add_argument("--block-bytes", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--sample-bytes", type=int, default=4096)
    parser.add_argument("--allow-buffered", action="store_true")
    args = parser.parse_args()
    raise SystemExit(load_checkpoint(args))


if __name__ == "__main__":
    main()
