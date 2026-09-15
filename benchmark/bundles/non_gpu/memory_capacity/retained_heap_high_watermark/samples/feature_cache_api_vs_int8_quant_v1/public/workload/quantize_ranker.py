#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import time


MIB = 1024 * 1024


def cgroup_path(name):
    candidates = [Path("/sys/fs/cgroup") / name]
    try:
        for line in Path("/proc/self/cgroup").read_text().splitlines():
            parts = line.split(":", 2)
            if len(parts) == 3 and parts[1] == "":
                rel = parts[2].lstrip("/")
                candidates.append(Path("/sys/fs/cgroup") / rel / name)
    except OSError:
        pass
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def read_cgroup_int(name):
    path = cgroup_path(name)
    raw = path.read_text().strip()
    if raw == "max":
        return None
    return int(raw)


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rss_kib():
    try:
        for line in Path("/proc/self/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        return 0
    return 0


def touch_buffer(size, seed):
    buf = bytearray(size)
    value = seed & 255
    for index in range(0, size, 4096):
        buf[index] = value
        value = (value + 17) & 255
    return buf


def materialize_phase(name, mib, chunk_mib, seed, peaks, kept):
    remaining = int(mib)
    chunk = max(1, int(chunk_mib))
    while remaining > 0:
        now = min(chunk, remaining)
        kept.append(touch_buffer(now * MIB, seed + len(kept)))
        remaining -= now
        peaks.append({"phase": name, "rss_kib": rss_kib(), "held_buffers": len(kept)})


def read_weights(path):
    raw = Path(path).read_bytes()
    if len(raw) % 4:
        raise ValueError("model weight file is not float32 aligned")
    values = [item[0] for item in struct.iter_unpack("<f", raw)]
    if not values:
        raise ValueError("model has no weights")
    return values


def count_calibration(path):
    rows = 0
    labels = 0
    with Path(path).open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            rows += 1
            item = json.loads(line)
            labels += int(item.get("label", 0))
    return rows, labels


def quantize(values):
    max_abs = max(abs(value) for value in values) or 1.0
    scale = max_abs / 127.0
    payload = bytearray()
    saturation = 0
    for value in values:
        q = int(round(value / scale))
        if q > 127:
            q = 127
            saturation += 1
        elif q < -127:
            q = -127
            saturation += 1
        payload.append(q & 255)
    return bytes(payload), scale, saturation


def load_config(start):
    for parent in [start, *start.parents]:
        config = parent / "config" / "quantization.json"
        if config.exists():
            return json.loads(config.read_text())
    raise FileNotFoundError("config/quantization.json not found")


def write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--calibration", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    config = load_config(Path(args.model).resolve().parent)
    report_path = Path(args.report)
    limit = read_cgroup_int("memory.max")
    current = read_cgroup_int("memory.current") or 0
    if not limit:
        write_json(report_path, {"schema_version": 1, "status": "no_cgroup_memory_limit"})
        print("MemoryError: cgroup memory.max is not fixed", file=sys.stderr)
        return 75

    limit_mib = limit // MIB
    required_mib = max(256, int(limit_mib * float(config["required_memory_percent"]) / 100.0))
    guard_mib = int(config["headroom_guard_mib"])
    headroom_mib = max(0, (limit - current) // MIB)
    started = time.time()
    base = {
        "schema_version": 1,
        "quantization_mode": config["quantization_mode"],
        "required_memory_mib": required_mib,
        "headroom_guard_mib": guard_mib,
        "cgroup_memory_max": limit,
        "cgroup_memory_current_before": current,
        "cgroup_headroom_mib_before": headroom_mib,
        "model_digest": sha256_file(args.model),
        "calibration_digest": sha256_file(args.calibration),
    }
    if headroom_mib < required_mib + guard_mib:
        payload = {
            **base,
            "status": "memory_headroom_insufficient",
            "reason": "cgroup_headroom_insufficient_for_tensor_materialization",
            "required_plus_guard_mib": required_mib + guard_mib,
        }
        write_json(report_path, payload)
        print(
            "MemoryError: cgroup_headroom_insufficient "
            f"headroom_mib={headroom_mib} required_mib={required_mib} guard_mib={guard_mib}",
            file=sys.stderr,
        )
        return 75

    kept = []
    peaks = [{"phase": "start", "rss_kib": rss_kib(), "held_buffers": 0}]
    phase_plan = [
        ("source_weights", math.ceil(required_mib * 0.34)),
        ("calibration_batches", math.ceil(required_mib * 0.24)),
        ("converted_tensors", math.ceil(required_mib * 0.27)),
        ("serialization_buffers", max(1, required_mib - math.ceil(required_mib * 0.85))),
    ]
    for index, (name, mib) in enumerate(phase_plan):
        materialize_phase(name, mib, int(config["chunk_mib"]), index * 31 + 7, peaks, kept)

    values = read_weights(args.model)
    rows, label_sum = count_calibration(args.calibration)
    if rows != int(config["expected_calibration_rows"]):
        raise ValueError(f"expected {config['expected_calibration_rows']} calibration rows, got {rows}")
    quantized, scale, saturation = quantize(values)
    validation_error = sum(abs(values[i] - (struct.unpack("b", bytes([quantized[i]]))[0] * scale)) for i in range(min(2048, len(values))))
    validation_error /= float(min(2048, len(values)))
    header = {
        "format": "cb_int8_ranker",
        "schema_version": 1,
        "operator_count": 14,
        "tensor_count": 9,
        "weight_count": len(values),
        "calibration_rows": rows,
        "label_sum": label_sum,
        "scale": scale,
        "saturation_count": saturation,
        "model_digest": base["model_digest"],
        "calibration_digest": base["calibration_digest"],
        "validation_mean_abs_error": validation_error,
    }
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as handle:
        handle.write(b"CBINT8RANKER 1\n")
        handle.write(json.dumps(header, sort_keys=True).encode("utf-8") + b"\n")
        handle.write(quantized)
    artifact_digest = sha256_file(out_path)
    stable_material = json.dumps(
        {
            "artifact_digest": artifact_digest,
            "calibration_digest": base["calibration_digest"],
            "model_digest": base["model_digest"],
            "quantization_mode": config["quantization_mode"],
            "rows": rows,
            "scale": round(scale, 12),
            "validation_mean_abs_error": round(validation_error, 12),
        },
        sort_keys=True,
    ).encode("utf-8")
    report = {
        **base,
        "status": "ok",
        "artifact": str(out_path),
        "artifact_digest": artifact_digest,
        "artifact_bytes": out_path.stat().st_size,
        "calibration_rows": rows,
        "operator_count": header["operator_count"],
        "tensor_count": header["tensor_count"],
        "validation_mean_abs_error": validation_error,
        "validation_tolerance": float(config["validation_tolerance"]),
        "stable_report_digest": hashlib.sha256(stable_material).hexdigest(),
        "peak_rss_kib": max(item["rss_kib"] for item in peaks),
        "phase_peaks": peaks,
        "elapsed_seconds": round(time.time() - started, 3),
    }
    write_json(report_path, report)
    print(f"QUANTIZATION_OK artifact={out_path} rows={rows} peak_rss_kib={report['peak_rss_kib']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
