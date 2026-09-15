#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import time

from artifact_io import (
    HEADER_LEN_BYTES,
    HEADER_TOTAL_BYTES,
    MIB,
    atomic_json,
    deterministic_block,
    sample_digest_for_file,
    stat_identity,
    tensor_prefix_digest,
)


def env_path(name):
    return pathlib.Path(os.environ[name])


def cfg():
    return {
        "sample_id": os.environ["SAMPLE_ID"],
        "checkpoint_id": os.environ["CHECKPOINT_ID"],
        "private_case": env_path("PRIVATE_CASE"),
        "a_root": env_path("A_VISIBLE_ROOT"),
        "b_root": env_path("B_CHECKPOINT_ROOT"),
        "tool_dir": env_path("B_TOOL_DIR"),
        "deadline_file": env_path("B_DEADLINE_FILE"),
        "a_count": int(os.environ["A_SHARD_COUNT"]),
        "a_mib": int(os.environ["A_SHARD_MIB"]),
        "b_count": int(os.environ["B_SHARD_COUNT"]),
        "b_mib": int(os.environ["B_SHARD_MIB"]),
        "block_bytes": int(os.environ["DIRECT_BLOCK_BYTES"]),
        "sample_bytes": int(os.environ["HASH_SAMPLE_BYTES"]),
        "default_deadline_ms": int(os.environ["B_DEFAULT_DEADLINE_MS"]),
        "margin_num": int(os.environ["DEADLINE_MARGIN_NUMERATOR"]),
        "margin_den": int(os.environ["DEADLINE_MARGIN_DENOMINATOR"]),
        "extra_ms": int(os.environ["DEADLINE_EXTRA_MS"]),
    }


def config_digest(c):
    keys = {
        "sample_id": c["sample_id"],
        "checkpoint_id": c["checkpoint_id"],
        "a_count": c["a_count"],
        "a_mib": c["a_mib"],
        "b_count": c["b_count"],
        "b_mib": c["b_mib"],
        "block_bytes": c["block_bytes"],
        "sample_bytes": c["sample_bytes"],
    }
    return hashlib.sha256(json.dumps(keys, sort_keys=True).encode()).hexdigest()


def shard_path(root, index):
    return pathlib.Path(root) / f"shard_{index:03d}.safetensors"


def tensor_specs(total_data_bytes, shard_id, family):
    unit = total_data_bytes // 4
    specs = []
    start = 0
    dtypes = ["F32", "F16", "F32", "I64"]
    names = ["embed", "mlp_gate", "attention_out", "norm_stats"]
    for idx, name in enumerate(names):
        end = start + unit if idx < 3 else total_data_bytes
        element_width = {"F32": 4, "F16": 2, "I64": 8}[dtypes[idx]]
        elements = max(1, (end - start) // element_width)
        specs.append(
            {
                "name": f"{family}.{shard_id}.{name}",
                "dtype": dtypes[idx],
                "shape": [elements],
                "data_offsets": [start, end],
            }
        )
        start = end
    return specs


def write_checkpoint_shard(path, shard_id, family, size_mib, block_bytes, sample_bytes):
    path = pathlib.Path(path)
    total_bytes = size_mib * MIB
    data_bytes = total_bytes - HEADER_TOTAL_BYTES
    tensors = tensor_specs(data_bytes, shard_id, family)
    header = {
        "__metadata__": {
            "format": "safetensors_fixture_v2",
            "checkpoint_family": family,
            "shard_id": shard_id,
            "payload_bytes": str(data_bytes),
        }
    }
    for tensor in tensors:
        header[tensor["name"]] = {
            "dtype": tensor["dtype"],
            "shape": tensor["shape"],
            "data_offsets": tensor["data_offsets"],
        }
    encoded = json.dumps(header, sort_keys=True, separators=(",", ":")).encode()
    if len(encoded) > HEADER_LEN_BYTES:
        raise ValueError(f"header too large for {path}: {len(encoded)}")
    padded_header = encoded + b" " * (HEADER_LEN_BYTES - len(encoded))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.write(struct.pack("<Q", HEADER_LEN_BYTES))
        handle.write(padded_header)
        remaining = data_bytes
        block_index = 0
        while remaining:
            chunk_size = min(block_bytes, remaining)
            handle.write(deterministic_block(f"{family}:{shard_id}", block_index, chunk_size))
            remaining -= chunk_size
            block_index += 1
        handle.flush()
        os.fsync(handle.fileno())
    sample_digest, observed_total = sample_digest_for_file(path, block_bytes, sample_bytes)
    selected = {}
    for tensor in tensors:
        selected[tensor["name"]] = tensor_prefix_digest(path, HEADER_TOTAL_BYTES, tensor["data_offsets"][0], min(sample_bytes, 4096))
    return {
        "shard_id": shard_id,
        "path": str(path),
        "bytes": observed_total,
        "block_sample_sha256": sample_digest,
        "tensor_prefix_sha256": selected,
        "tensor_count": len(tensors),
        "tensors": tensors,
    }


def install_tools(c):
    c["tool_dir"].mkdir(parents=True, exist_ok=True)
    for name in ("load_checkpoint_smoke.py", "artifact_io.py"):
        src = c["private_case"] / "data" / name
        dst = c["tool_dir"] / name
        shutil.copy2(src, dst)
        dst.chmod(0o755)


def existing_ok(c):
    summary = c["b_root"].parent / "fixture_summary.json"
    if not summary.exists():
        return False
    try:
        data = json.loads(summary.read_text())
    except Exception:
        return False
    if data.get("config_digest") != config_digest(c):
        return False
    required = [c["a_root"] / "shard_index.json", c["b_root"] / "manifest.json", c["deadline_file"]]
    required.extend(shard_path(c["a_root"], idx) for idx in range(c["a_count"]))
    required.extend(shard_path(c["b_root"], idx) for idx in range(c["b_count"]))
    return all(path.exists() and path.stat().st_size > 0 for path in required)


def write_index(path, payload):
    atomic_json(path, payload)
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def prepare():
    c = cfg()
    pathlib.Path("/work/artifact_volume").mkdir(parents=True, exist_ok=True)
    c["a_root"].mkdir(parents=True, exist_ok=True)
    c["b_root"].mkdir(parents=True, exist_ok=True)
    install_tools(c)
    if existing_ok(c):
        print(json.dumps({"prepared": True, "reused": True, "summary": str(c["b_root"].parent / "fixture_summary.json")}))
        return

    for root in (c["a_root"], c["b_root"]):
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True, exist_ok=True)
    install_tools(c)

    a_shards = [
        write_checkpoint_shard(shard_path(c["a_root"], idx), f"audit-{idx:03d}", "registry_audit", c["a_mib"], c["block_bytes"], c["sample_bytes"])
        for idx in range(c["a_count"])
    ]
    b_shards = [
        write_checkpoint_shard(shard_path(c["b_root"], idx), f"candidate-{idx:03d}", "candidate_cpu", c["b_mib"], c["block_bytes"], c["sample_bytes"])
        for idx in range(c["b_count"])
    ]
    a_index = {
        "format": "model_registry_audit_index_v2",
        "checkpoint_id": c["checkpoint_id"],
        "shard_count": len(a_shards),
        "total_bytes": sum(item["bytes"] for item in a_shards),
        "shards": a_shards,
    }
    b_manifest = {
        "format": "candidate_checkpoint_manifest_v2",
        "checkpoint_id": "candidate-cpu-smoke-2026w30",
        "shard_count": len(b_shards),
        "total_bytes": sum(item["bytes"] for item in b_shards),
        "expected_output_seed": "candidate-cpu-smoke-2026w30",
        "shards": b_shards,
    }
    a_digest = write_index(c["a_root"] / "shard_index.json", a_index)
    b_digest = write_index(c["b_root"] / "manifest.json", b_manifest)
    c["deadline_file"].write_text(str(c["default_deadline_ms"]) + "\n")
    c["deadline_file"].chmod(0o644)
    summary = {
        "prepared": True,
        "reused": False,
        "config_digest": config_digest(c),
        "sample_id": c["sample_id"],
        "a_index_sha256": a_digest,
        "b_manifest_sha256": b_digest,
        "a_identity": stat_identity(c["a_root"]),
        "b_identity": stat_identity(c["b_root"]),
        "same_st_dev": stat_identity(c["a_root"])["st_dev"] == stat_identity(c["b_root"])["st_dev"],
        "a_shard_count": c["a_count"],
        "a_shard_mib": c["a_mib"],
        "b_shard_count": c["b_count"],
        "b_shard_mib": c["b_mib"],
    }
    atomic_json(c["b_root"].parent / "fixture_summary.json", summary)
    print(json.dumps({"prepared": True, "reused": False, "summary": str(c["b_root"].parent / "fixture_summary.json")}))


def run_loader(c, out_path, deadline_ms):
    command = [
        sys.executable,
        str(c["tool_dir"] / "load_checkpoint_smoke.py"),
        "--checkpoint",
        str(c["b_root"]),
        "--manifest",
        str(c["b_root"] / "manifest.json"),
        "--out",
        str(out_path),
        "--deadline-ms",
        str(deadline_ms),
    ]
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def calibrate(trials):
    prepare()
    c = cfg()
    results = []
    for idx in range(trials):
        out = pathlib.Path(f"/tmp/model_load_calibration_{os.getpid()}_{idx}.json")
        out.unlink(missing_ok=True)
        proc = run_loader(c, out, 0)
        if proc.returncode != 0:
            raise SystemExit(f"load calibration failed rc={proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        data = json.loads(out.read_text())
        results.append(data)
        out.unlink(missing_ok=True)
    max_elapsed = max(int(item["elapsed_ms"]) for item in results)
    deadline = int(math.ceil(max_elapsed * c["margin_num"] / c["margin_den"])) + c["extra_ms"]
    c["deadline_file"].write_text(str(deadline) + "\n")
    payload = {
        "trials": trials,
        "deadline_ms": deadline,
        "elapsed_ms": [item["elapsed_ms"] for item in results],
        "bytes_read": [item["bytes_read"] for item in results],
        "process_read_bytes_delta": [item.get("process_read_bytes_delta", 0) for item in results],
        "direct_modes": [item.get("direct_read") for item in results],
    }
    atomic_json(c["tool_dir"] / "load_calibration.json", payload)
    print(json.dumps(payload, sort_keys=True))


def identity():
    prepare()
    c = cfg()
    def file_identities(root):
        values = []
        for path in sorted(root.glob("*.safetensors")):
            st = path.stat()
            values.append({"path": str(path.resolve()), "st_dev": st.st_dev, "st_ino": st.st_ino})
        return values
    a_files = file_identities(c["a_root"])
    b_files = file_identities(c["b_root"])
    a_inode_keys = {(item["st_dev"], item["st_ino"]) for item in a_files}
    b_inode_keys = {(item["st_dev"], item["st_ino"]) for item in b_files}
    a_paths = {item["path"] for item in a_files}
    b_paths = {item["path"] for item in b_files}
    payload = {
        "a_root": stat_identity(c["a_root"]),
        "b_root": stat_identity(c["b_root"]),
        "same_st_dev": stat_identity(c["a_root"])["st_dev"] == stat_identity(c["b_root"])["st_dev"],
        "a_file_count": len(a_files),
        "b_file_count": len(b_files),
        "shared_inode_count": len(a_inode_keys & b_inode_keys),
        "shared_resolved_path_count": len(a_paths & b_paths),
        "logical_overlap": sorted(a_paths & b_paths),
    }
    print(json.dumps(payload, sort_keys=True, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("prepare", "calibrate", "identity"))
    parser.add_argument("--trials", type=int, default=2)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "calibrate":
        calibrate(args.trials)
    else:
        identity()


if __name__ == "__main__":
    main()
