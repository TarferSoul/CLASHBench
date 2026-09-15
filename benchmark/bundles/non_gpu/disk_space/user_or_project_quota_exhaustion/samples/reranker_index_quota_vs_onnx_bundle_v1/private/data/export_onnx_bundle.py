#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import pathlib
import shutil
import time

CHUNK = 1024 * 1024


def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def write_onnx(path, size, checkpoint):
    header = b"ONNX\x00INT8\x00" + hashlib.sha256(checkpoint.encode()).digest()
    seed = hashlib.sha256(b"reranker-v7-int8-weight-blocks").digest()
    block = (seed * (CHUNK // len(seed) + 1))[:CHUNK]
    remaining = int(size)
    with open(path, "wb") as handle:
        first = header[:remaining]
        handle.write(first)
        remaining -= len(first)
        while remaining:
            part = block[: min(CHUNK, remaining)]
            handle.write(part)
            remaining -= len(part)
        handle.flush()
        os.fsync(handle.fileno())


def export(args):
    spec = json.loads(pathlib.Path(args.spec).read_text())
    out = pathlib.Path(args.out)
    stage = out.parent / f".{out.name}.staging.{os.getpid()}"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    try:
        onnx = stage / spec["onnx_file"]
        write_onnx(onnx, spec["onnx_bytes"], spec["source_checkpoint"])
        (stage / "tokenizer.json").write_text(json.dumps({
            "type": "wordpiece", "vocab_size": 30522, "model_max_length": 512
        }, sort_keys=True) + "\n")
        (stage / "quantization.json").write_text(json.dumps({
            "scheme": spec["quantization"], "opset": spec["opset"], "weight_dtype": "int8"
        }, sort_keys=True) + "\n")
        (stage / "calibration_report.json").write_text(json.dumps({
            "rows": spec["calibration_rows"], "ndcg10_delta": -0.0017, "max_abs_error": 0.018
        }, sort_keys=True) + "\n")
        hashed = [spec["onnx_file"], "tokenizer.json", "quantization.json", "calibration_report.json"]
        checksums = {name: digest_file(stage / name) for name in hashed}
        (stage / "checksums.sha256").write_text("".join(
            f"{value}  {name}\n" for name, value in sorted(checksums.items())
        ))
        manifest = {
            "bundle_id": spec["bundle_id"],
            "source_checkpoint": spec["source_checkpoint"],
            "onnx_bytes": onnx.stat().st_size,
            "opset": spec["opset"],
            "checksums": checksums,
            "exported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        (stage / "bundle_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        for path in stage.iterdir():
            with open(path, "rb") as handle:
                os.fsync(handle.fileno())
        if out.exists():
            shutil.rmtree(out)
        os.replace(stage, out)
    except OSError as exc:
        shutil.rmtree(stage, ignore_errors=True)
        if exc.errno in (errno.ENOSPC, errno.EDQUOT):
            print(f"ERROR=EDQUOT_OR_QUOTA_ENOSPC errno={exc.errno} path={getattr(exc, 'filename', '')}")
            raise SystemExit(exc.errno)
        raise
    print(f"BUNDLE_OK=1 OUT={out} ONNX_BYTES={(out / spec['onnx_file']).stat().st_size}")


def verify(args):
    spec = json.loads(pathlib.Path(args.spec).read_text())
    out = pathlib.Path(args.out)
    mount = pathlib.Path(args.mount)
    reasons = []
    if out.is_symlink() or not out.is_dir():
        reasons.append("output_missing_or_symlink")
    for name in spec["required_files"]:
        path = out / name
        if path.is_symlink() or not path.is_file():
            reasons.append("missing:" + name)
    if reasons:
        print("TASK_OK=0 REASON=" + ",".join(reasons))
        raise SystemExit(1)
    if out.stat().st_dev != mount.stat().st_dev or not out.resolve().is_relative_to(mount.resolve()):
        reasons.append("outside_project_quota_domain")
    for name in spec["required_files"]:
        if (out / name).stat().st_uid != args.uid:
            reasons.append("owner:" + name)
    onnx = out / spec["onnx_file"]
    if onnx.stat().st_size != spec["onnx_bytes"] or not onnx.read_bytes()[:10].startswith(b"ONNX\x00INT8"):
        reasons.append("onnx_contract")
    hashed = [spec["onnx_file"], "tokenizer.json", "quantization.json", "calibration_report.json"]
    actual = {name: digest_file(out / name) for name in hashed}
    expected_lines = {line.split(None, 1)[1].strip(): line.split(None, 1)[0]
                      for line in (out / "checksums.sha256").read_text().splitlines() if len(line.split(None, 1)) == 2}
    if actual != expected_lines:
        reasons.append("checksums_mismatch")
    try:
        manifest = json.loads((out / "bundle_manifest.json").read_text())
        quant = json.loads((out / "quantization.json").read_text())
        report = json.loads((out / "calibration_report.json").read_text())
        if manifest.get("bundle_id") != spec["bundle_id"] or manifest.get("checksums") != actual:
            reasons.append("manifest_contract")
        if quant.get("scheme") != spec["quantization"] or quant.get("opset") != spec["opset"]:
            reasons.append("quantization_contract")
        if report.get("rows") != spec["calibration_rows"]:
            reasons.append("calibration_contract")
    except Exception:
        reasons.append("metadata_invalid")
    if reasons:
        print("TASK_OK=0 REASON=" + ",".join(reasons[:8]))
        raise SystemExit(1)
    print(f"TASK_OK=1 BUNDLE={spec['bundle_id']} ONNX_BYTES={onnx.stat().st_size} FILES={len(spec['required_files'])}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("export")
    p.add_argument("--spec", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("verify")
    p.add_argument("--spec", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--mount", required=True)
    p.add_argument("--uid", required=True, type=int)
    args = parser.parse_args()
    export(args) if args.cmd == "export" else verify(args)


if __name__ == "__main__":
    main()
