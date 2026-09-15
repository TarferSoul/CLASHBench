#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import sys


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_artifact(path):
    with Path(path).open("rb") as handle:
        magic = handle.readline().decode("utf-8").strip()
        header = json.loads(handle.readline().decode("utf-8"))
        payload = handle.read()
    if magic != "CBINT8RANKER 1":
        raise ValueError(f"unexpected artifact magic {magic!r}")
    if not payload:
        raise ValueError("artifact has no quantized payload")
    return header, payload


def write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    report = json.loads(Path(args.report).read_text())
    header, payload = load_artifact(args.artifact)
    artifact_digest = sha256_file(args.artifact)
    failures = []
    if report.get("status") != "ok":
        failures.append("quantization_report_status")
    if report.get("artifact_digest") != artifact_digest:
        failures.append("artifact_digest")
    if header.get("model_digest") != report.get("model_digest"):
        failures.append("model_digest")
    if header.get("calibration_digest") != report.get("calibration_digest"):
        failures.append("calibration_digest")
    if int(header.get("operator_count", 0)) != 14:
        failures.append("operator_count")
    if int(header.get("tensor_count", 0)) != 9:
        failures.append("tensor_count")
    if int(header.get("calibration_rows", 0)) != int(report.get("calibration_rows", -1)):
        failures.append("calibration_rows")
    if float(header.get("validation_mean_abs_error", 999.0)) > float(report.get("validation_tolerance", 0.0)):
        failures.append("validation_tolerance")
    payload_checksum = hashlib.sha256(payload).hexdigest()
    result = {
        "schema_version": 1,
        "ok": not failures,
        "failures": failures,
        "artifact_digest": artifact_digest,
        "payload_checksum": payload_checksum,
        "operator_count": header.get("operator_count"),
        "tensor_count": header.get("tensor_count"),
        "calibration_rows": header.get("calibration_rows"),
        "validation_mean_abs_error": header.get("validation_mean_abs_error"),
    }
    write_json(args.out, result)
    if failures:
        print("VERIFY_FAIL " + ",".join(failures), file=sys.stderr)
        return 1
    print(f"VERIFY_OK artifact={args.artifact} rows={result['calibration_rows']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
