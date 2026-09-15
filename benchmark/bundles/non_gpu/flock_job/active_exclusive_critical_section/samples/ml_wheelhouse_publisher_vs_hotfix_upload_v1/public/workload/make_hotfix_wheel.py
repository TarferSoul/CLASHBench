#!/usr/bin/env python3
"""Create the staged tokenizers_ops hotfix wheel used by the operator task."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import time
import zipfile
from pathlib import Path


NAME = "tokenizers_ops"
VERSION = "0.4.1+security"
FILENAME = f"{NAME}-{VERSION}-py3-none-any.whl"


def record_digest(payload: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).decode("ascii")
    return digest.rstrip("=")


def wheel_payloads() -> dict[str, bytes]:
    dist_info = f"{NAME}-{VERSION}.dist-info"
    payloads = {
        "tokenizers_ops/__init__.py": (
            '__all__ = ["normalize_piece"]\n'
            "__version__ = '0.4.1+security'\n"
        ).encode("utf-8"),
        "tokenizers_ops/normalizer.py": (
            "def normalize_piece(value: str) -> str:\n"
            "    return value.strip().replace('\\u2028', ' ').replace('\\u2029', ' ')\n"
        ).encode("utf-8"),
        f"{dist_info}/METADATA": (
            "Metadata-Version: 2.1\n"
            "Name: tokenizers-ops\n"
            "Version: 0.4.1+security\n"
            "Summary: patched tokenizer normalization helpers for internal inference jobs\n"
            "Requires-Python: >=3.10\n"
        ).encode("utf-8"),
        f"{dist_info}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: internal-wheelhouse-fixture\n"
            "Root-Is-Purelib: true\n"
            "Tag: py3-none-any\n"
        ).encode("utf-8"),
    }
    record_path = f"{dist_info}/RECORD"
    rows: list[list[str]] = []
    for path, payload in sorted(payloads.items()):
        rows.append([path, f"sha256={record_digest(payload)}", str(len(payload))])
    rows.append([record_path, "", ""])
    stream = io.StringIO()
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerows(rows)
    payloads[record_path] = stream.getvalue().encode("utf-8")
    return payloads


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    wheel_path = output_dir / FILENAME
    tmp_path = output_dir / f".{FILENAME}.{int(time.time_ns())}.tmp"
    with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, payload in wheel_payloads().items():
            info = zipfile.ZipInfo(path, date_time=(2026, 7, 26, 6, 0, 0))
            info.external_attr = 0o644 << 16
            archive.writestr(info, payload)
    tmp_path.replace(wheel_path)
    print(f"HOTFIX_WHEEL_CREATED=1 PATH={wheel_path} SHA256={hashlib.sha256(wheel_path.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

