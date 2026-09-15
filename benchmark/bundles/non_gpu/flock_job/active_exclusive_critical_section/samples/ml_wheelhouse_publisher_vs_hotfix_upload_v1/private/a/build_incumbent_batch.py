#!/usr/bin/env python3
"""Build a deterministic batch of structurally valid internal ML wheels."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import json
import shutil
import zipfile
from pathlib import Path


PREFIXES = [
    "attention-cache",
    "batch-router",
    "embedding-filter",
    "feature-normalizer",
    "gradient-audit",
    "inference-metrics",
    "kernel-selector",
    "logit-sampler",
    "model-card",
    "prompt-redactor",
]


def digest(payload: bytes) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).decode("ascii").rstrip("=")


def wheel_payloads(project: str, version: str, index: int) -> dict[str, bytes]:
    module = project.replace("-", "_")
    dist = f"{module}-{version}.dist-info"
    payloads = {
        f"{module}/__init__.py": f"BUILD_INDEX = {index}\n".encode("utf-8"),
        f"{module}/metadata.py": (
            f"PROJECT = {project!r}\nVERSION = {version!r}\n"
            f"FINGERPRINT = {hashlib.sha256(f'{project}:{version}:{index}'.encode()).hexdigest()!r}\n"
        ).encode("utf-8"),
        f"{dist}/METADATA": (
            "Metadata-Version: 2.1\n"
            f"Name: {project}\n"
            f"Version: {version}\n"
            "Summary: internal ML platform wheelhouse fixture package\n"
            "Requires-Python: >=3.10\n"
        ).encode("utf-8"),
        f"{dist}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: ml-wheelhouse-maintenance\n"
            "Root-Is-Purelib: true\n"
            "Tag: py3-none-any\n"
        ).encode("utf-8"),
    }
    record_name = f"{dist}/RECORD"
    rows = [[path, f"sha256={digest(payload)}", str(len(payload))] for path, payload in sorted(payloads.items())]
    rows.append([record_name, "", ""])
    stream = io.StringIO()
    csv.writer(stream, lineterminator="\n").writerows(rows)
    payloads[record_name] = stream.getvalue().encode("utf-8")
    return payloads


def create_wheel(root: Path, index: int) -> Path:
    project = PREFIXES[index % len(PREFIXES)]
    version = f"2.{index // len(PREFIXES)}.{index % len(PREFIXES)}"
    module = project.replace("-", "_")
    filename = f"{module}-{version}-py3-none-any.whl"
    wheel = root / filename
    with zipfile.ZipFile(wheel, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, payload in wheel_payloads(project, version, index).items():
            info = zipfile.ZipInfo(path, date_time=(2026, 7, 26, 6, 0, 0))
            info.external_attr = 0o644 << 16
            archive.writestr(info, payload)
    return wheel


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--count", type=int, required=True)
    args = parser.parse_args()
    output = Path(args.output)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    manifest = []
    for index in range(args.count):
        wheel = create_wheel(output, index)
        manifest.append(
            {
                "filename": wheel.name,
                "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
                "size": wheel.stat().st_size,
            }
        )
    (output / "batch_manifest.json").write_text(
        json.dumps({"wheel_count": len(manifest), "wheels": manifest}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"INCUMBENT_BATCH_READY=1 WHEELS={len(manifest)} OUTPUT={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
