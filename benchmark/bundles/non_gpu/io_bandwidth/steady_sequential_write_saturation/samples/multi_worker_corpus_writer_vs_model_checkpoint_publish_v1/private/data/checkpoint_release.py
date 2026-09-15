#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import sys
import time


MIB = 1024 * 1024


def write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def fsync_file(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    fsync_file(tmp)
    tmp.replace(path)
    fsync_dir(path.parent)


def clean_dir(path):
    path = pathlib.Path(path)
    if path.exists():
        for item in sorted(path.glob("**/*"), key=lambda p: len(p.parts), reverse=True):
            if item.is_file() or item.is_symlink():
                item.unlink()
            elif item.is_dir():
                item.rmdir()
    path.mkdir(parents=True, exist_ok=True)


def block_for(label, size):
    seed = hashlib.sha256(label.encode()).digest() + label.encode() + b"\n"
    return (seed * ((size // len(seed)) + 1))[:size]


def write_source_tensor(path, label, size):
    block = block_for(label, min(MIB, size))
    remaining = size
    sha = hashlib.sha256()
    fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
    try:
        while remaining > 0:
            chunk = block if remaining >= len(block) else block[:remaining]
            write_all(fd, chunk)
            sha.update(chunk)
            remaining -= len(chunk)
        os.fsync(fd)
    finally:
        os.close(fd)
    return sha.hexdigest()


def prepare(args):
    source = pathlib.Path(args.source)
    clean_dir(source)
    tensor_dir = source / "tensors"
    tensor_dir.mkdir(parents=True, exist_ok=True)
    tensors = []
    tensor_bytes = args.tensor_mib * MIB
    for idx in range(args.shards):
        name = f"tensor-{idx:03d}.safetensors"
        path = tensor_dir / name
        sha = write_source_tensor(path, f"{args.model_id}:{args.revision}:{idx}", tensor_bytes)
        tensors.append({
            "name": name,
            "relative_path": f"tensors/{name}",
            "bytes": tensor_bytes,
            "sha256": sha,
            "dtype": "float16",
            "shape": [1024, tensor_bytes // 2048],
        })
    metadata = {
        "model_id": args.model_id,
        "revision": args.revision,
        "format": "deterministic_safetensors_fixture_v1",
        "tensor_count": len(tensors),
        "total_tensor_bytes": sum(item["bytes"] for item in tensors),
        "tensors": tensors,
    }
    atomic_json(source / "checkpoint_manifest.json", metadata)
    atomic_json(args.expected_manifest, metadata)
    atomic_json(source / "config.json", {
        "architectures": ["LocalRerankerForSequenceScoring"],
        "hidden_size": 1024,
        "num_hidden_layers": 12,
        "torch_dtype": "float16",
        "model_id": args.model_id,
    })
    atomic_json(source / "tokenizer.json", {"model": "bytepair_fixture", "revision": args.revision})
    fsync_dir(source)
    print(json.dumps({"prepared": True, "source": str(source), "total_tensor_bytes": metadata["total_tensor_bytes"]}, sort_keys=True))


def elapsed_ms(start):
    return int((time.monotonic() - start) * 1000)


def copy_tensor(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_TRUNC | os.O_WRONLY
    flags |= getattr(os, "O_DSYNC", getattr(os, "O_SYNC", 0))
    sha = hashlib.sha256()
    byte_count = 0
    with pathlib.Path(src).open("rb") as inp:
        fd = os.open(dst, flags, 0o644)
        try:
            for chunk in iter(lambda: inp.read(MIB), b""):
                write_all(fd, chunk)
                sha.update(chunk)
                byte_count += len(chunk)
            os.fsync(fd)
        finally:
            os.close(fd)
    fsync_dir(dst.parent)
    return {"bytes": byte_count, "sha256": sha.hexdigest()}


def write_text_file(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(text)
    fsync_file(tmp)
    tmp.replace(path)
    fsync_dir(path.parent)


def build_manifest_payload(expected, output, copied, start, deadline_ms, complete, deadline_missed):
    return {
        "complete": bool(complete and not deadline_missed),
        "deadline_missed": bool(deadline_missed),
        "fsync_completed": bool(complete and not deadline_missed),
        "format": "inference_serving_release_v1",
        "model_id": expected["model_id"],
        "revision": expected["revision"],
        "output": str(output),
        "output_st_dev": os.stat(output).st_dev,
        "tensor_count": len(copied),
        "expected_tensor_count": len(expected["tensors"]),
        "total_bytes": sum(int(item["bytes"]) for item in copied),
        "expected_total_bytes": int(expected["total_tensor_bytes"]),
        "deadline_ms": int(deadline_ms),
        "total_elapsed_ms": elapsed_ms(start),
        "tensors": copied,
    }


def publish(args):
    source = pathlib.Path(args.source)
    output = pathlib.Path(args.output)
    manifest = pathlib.Path(args.manifest)
    expected = json.loads(pathlib.Path(args.expected_manifest).read_text())
    clean_dir(output)
    (output / "tensors").mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    copied = []
    deadline_missed = False
    write_text_file(output / "README.release", f"model_id={expected['model_id']}\nrevision={expected['revision']}\n")
    shutil.copy2(source / "config.json", output / "config.json")
    fsync_file(output / "config.json")
    shutil.copy2(source / "tokenizer.json", output / "tokenizer.json")
    fsync_file(output / "tokenizer.json")
    fsync_dir(output)
    for tensor in expected["tensors"]:
        if args.deadline_ms and elapsed_ms(start) > args.deadline_ms:
            deadline_missed = True
            break
        src = source / tensor["relative_path"]
        dst = output / tensor["relative_path"]
        result = copy_tensor(src, dst)
        record = dict(tensor)
        record.update({
            "path": str(dst),
            "bytes": result["bytes"],
            "sha256": result["sha256"],
        })
        copied.append(record)
        atomic_json(output / "tensor_manifest.partial.json", build_manifest_payload(expected, output, copied, start, args.deadline_ms, False, False))
        if args.deadline_ms and elapsed_ms(start) > args.deadline_ms and len(copied) < len(expected["tensors"]):
            deadline_missed = True
            break
    complete = len(copied) == len(expected["tensors"])
    if complete and not deadline_missed:
        write_text_file(output / "fsync_completed.marker", f"completed_at={time.time():.6f}\n")
        final = build_manifest_payload(expected, output, copied, start, args.deadline_ms, True, False)
        atomic_json(manifest, final)
        print(json.dumps(final, sort_keys=True))
        return 0
    partial = build_manifest_payload(expected, output, copied, start, args.deadline_ms, False, deadline_missed)
    atomic_json(output / "tensor_manifest.partial.json", partial)
    print(json.dumps(partial, sort_keys=True), file=sys.stderr)
    return 124 if deadline_missed else 1


def validate(args):
    source = pathlib.Path(args.source)
    output = pathlib.Path(args.output)
    manifest_path = pathlib.Path(args.manifest)
    expected = json.loads(pathlib.Path(args.expected_manifest).read_text())
    errors = []
    data = {}
    if not manifest_path.exists():
        errors.append("manifest_missing")
    else:
        try:
            data = json.loads(manifest_path.read_text())
        except Exception as exc:
            errors.append(f"manifest_json:{type(exc).__name__}")
    if data.get("complete") is not True:
        errors.append("manifest_not_complete")
    if data.get("fsync_completed") is not True:
        errors.append("fsync_not_complete")
    if not (output / "fsync_completed.marker").exists():
        errors.append("fsync_marker_missing")
    if int(data.get("tensor_count", -1)) != len(expected["tensors"]):
        errors.append("tensor_count")
    if int(data.get("total_bytes", 0)) < int(args.min_total_mib * MIB):
        errors.append("total_bytes")
    if args.max_elapsed_ms and int(data.get("total_elapsed_ms", 10**12)) > args.max_elapsed_ms:
        errors.append("deadline")
    if output.exists() and source.exists() and os.stat(output).st_dev != os.stat(source).st_dev:
        errors.append("source_output_device")
    manifest_tensors = {item.get("relative_path"): item for item in data.get("tensors", [])}
    validated_bytes = 0
    for tensor in expected["tensors"]:
        item = manifest_tensors.get(tensor["relative_path"])
        if not item:
            errors.append(f"missing_manifest_tensor:{tensor['name']}")
            continue
        path = pathlib.Path(item.get("path", output / tensor["relative_path"]))
        if not path.exists():
            errors.append(f"missing_file:{tensor['name']}")
            continue
        size = path.stat().st_size
        if size != int(tensor["bytes"]):
            errors.append(f"size:{tensor['name']}")
        sha = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(MIB), b""):
                sha.update(chunk)
        if sha.hexdigest() != tensor["sha256"] or item.get("sha256") != tensor["sha256"]:
            errors.append(f"sha256:{tensor['name']}")
        validated_bytes += size
    result = {
        "valid": not errors,
        "errors": errors,
        "validated_bytes": validated_bytes,
        "expected_bytes": expected["total_tensor_bytes"],
        "total_elapsed_ms": data.get("total_elapsed_ms"),
        "tensor_count": len(manifest_tensors),
    }
    try:
        atomic_json(output / "release_validation.json", result)
    except Exception:
        pass
    print(json.dumps(result, sort_keys=True))
    if errors:
        raise SystemExit(1)


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd")
    p = sub.add_parser("prepare")
    p.add_argument("--source", required=True)
    p.add_argument("--expected-manifest", required=True)
    p.add_argument("--shards", type=int, required=True)
    p.add_argument("--tensor-mib", type=int, required=True)
    p.add_argument("--model-id", required=True)
    p.add_argument("--revision", required=True)
    pub = sub.add_parser("publish")
    pub.add_argument("--source", required=True)
    pub.add_argument("--output", required=True)
    pub.add_argument("--manifest", required=True)
    pub.add_argument("--expected-manifest", required=True)
    pub.add_argument("--deadline-ms", type=int, default=0)
    v = sub.add_parser("validate")
    v.add_argument("--source", required=True)
    v.add_argument("--output", required=True)
    v.add_argument("--manifest", required=True)
    v.add_argument("--expected-manifest", required=True)
    v.add_argument("--max-elapsed-ms", type=int, default=0)
    v.add_argument("--min-total-mib", type=int, default=0)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "prepare":
        prepare(args)
    elif args.cmd == "publish":
        raise SystemExit(publish(args))
    elif args.cmd == "validate":
        validate(args)
    else:
        parser.print_help()
        raise SystemExit(2)


if __name__ == "__main__":
    main()

