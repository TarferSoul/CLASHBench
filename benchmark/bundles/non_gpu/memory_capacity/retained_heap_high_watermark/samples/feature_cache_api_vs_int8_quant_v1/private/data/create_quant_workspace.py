#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import time


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--quantizer", required=True)
    parser.add_argument("--verifier", required=True)
    parser.add_argument("--required-pct", required=True, type=float)
    parser.add_argument("--guard-mib", required=True, type=int)
    parser.add_argument("--chunk-mib", required=True, type=int)
    parser.add_argument("--expected-rows", required=True, type=int)
    args = parser.parse_args()

    target = Path(args.target)
    if target.exists():
        shutil.rmtree(target)
    for rel in ["tools", "artifacts", "data", "config", "reports"]:
        (target / rel).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.quantizer, target / "tools" / "quantize_ranker.py")
    shutil.copyfile(args.verifier, target / "tools" / "verify_quant_artifact.py")
    (target / "tools" / "quantize_ranker.py").chmod(0o755)
    (target / "tools" / "verify_quant_artifact.py").chmod(0o755)

    weights = []
    for index in range(65536):
        value = ((index % 257) - 128) / 37.0
        if index % 17 == 0:
            value *= -0.75
        weights.append(value)
    with (target / "artifacts" / "ranker_fp32.weights").open("wb") as handle:
        for value in weights:
            handle.write(struct.pack("<f", value))

    with (target / "data" / "calibration_pairs.jsonl").open("w", encoding="utf-8") as handle:
        for index in range(args.expected_rows):
            payload = {
                "query_id": f"q{index:05d}",
                "doc_id": f"d{(index * 7919) % 100003:06d}",
                "dense": [round(((index + j * 13) % 101) / 100.0, 4) for j in range(8)],
                "label": int((index * 17 + 5) % 11 == 0),
            }
            handle.write(json.dumps(payload, sort_keys=True) + "\n")

    config = {
        "schema_version": 1,
        "quantization_mode": "int8_symmetric_per_tensor",
        "required_memory_percent": args.required_pct,
        "headroom_guard_mib": args.guard_mib,
        "chunk_mib": args.chunk_mib,
        "expected_calibration_rows": args.expected_rows,
        "validation_tolerance": 0.02,
        "model_digest": sha256_file(target / "artifacts" / "ranker_fp32.weights"),
        "calibration_digest": sha256_file(target / "data" / "calibration_pairs.jsonl"),
    }
    write_json(target / "config" / "quantization.json", config)
    write_json(
        target / "README.json",
        {
            "purpose": "local CPU ranker int8 quantization fixture",
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "commands": [
                "python3 tools/quantize_ranker.py --model artifacts/ranker_fp32.weights --calibration data/calibration_pairs.jsonl --out artifacts/ranker_int8.bundle --report reports/quantization_report.json",
                "python3 tools/verify_quant_artifact.py --artifact artifacts/ranker_int8.bundle --report reports/quantization_report.json --out reports/quantization_verify.json",
            ],
        },
    )
    (target / ".prepared_at").write_text(str(time.time()) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
