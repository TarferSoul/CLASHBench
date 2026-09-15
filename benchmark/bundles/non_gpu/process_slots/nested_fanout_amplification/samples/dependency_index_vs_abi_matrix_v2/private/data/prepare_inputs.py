#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


def write_source(path: Path, package: int, unit: int, functions: int) -> None:
    lines = [
        "#include <stdint.h>",
        f"uint64_t pkg_{package}_unit_{unit}_entry(uint64_t value) {{",
        f"  return value ^ UINT64_C({package * 1009 + unit * 97 + 17});",
        "}",
    ]
    for idx in range(functions):
        salt = package * 1000003 + unit * 10007 + idx * 131 + 29
        lines.extend(
            [
                f"uint64_t pkg_{package}_unit_{unit}_symbol_{idx}(uint64_t value) {{",
                f"  value ^= UINT64_C({salt});",
                "  value = (value << 7) | (value >> 57);",
                f"  return value + UINT64_C({salt + 41});",
                "}",
            ]
        )
    path.write_text("\n".join(lines) + "\n")


def write_index_fixture(path: Path, project: int, source: int, target_bytes: int) -> None:
    header = [f"# project_{project} source_{source}", "from __future__ import annotations", ""]
    block = []
    idx = 0
    while sum(len(line) + 1 for line in header + block) < target_bytes:
        block.extend(
            [
                f"def dependency_{project}_{source}_{idx}(value: int) -> int:",
                f"    token = value ^ {project * 100003 + source * 1009 + idx}",
                f"    return (token * {idx + 3}) % 2147483647",
                "",
            ]
        )
        idx += 1
    path.write_text("\n".join(header + block) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--a-root", required=True)
    parser.add_argument("--a-files", type=int, required=True)
    parser.add_argument("--a-kib", type=int, required=True)
    parser.add_argument("--b-root", required=True)
    parser.add_argument("--b-workers", type=int, required=True)
    parser.add_argument("--b-units", type=int, required=True)
    args = parser.parse_args()

    a_root = Path(args.a_root)
    b_root = Path(args.b_root)
    a_root.mkdir(parents=True, exist_ok=True)
    b_root.mkdir(parents=True, exist_ok=True)

    for source in range(args.a_files):
        write_index_fixture(
            a_root / f"module_{source:02d}.py",
            source % args.b_workers,
            source,
            args.a_kib * 1024,
        )

    entries = []
    for package in range(args.b_workers):
        package_dir = b_root / f"package_{package:02d}"
        package_dir.mkdir(parents=True, exist_ok=True)
        for unit in range(args.b_units):
            source_path = package_dir / f"unit_{unit:02d}.c"
            write_source(source_path, package, unit, functions=1800)
            entries.append(
                {
                    "package": package,
                    "unit": unit,
                    "path": str(source_path.relative_to(b_root)),
                    "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                }
            )
    (b_root / "input-manifest.json").write_text(
        json.dumps({"packages": args.b_workers, "units_per_package": args.b_units, "sources": entries}, indent=2)
        + "\n"
    )


if __name__ == "__main__":
    main()
