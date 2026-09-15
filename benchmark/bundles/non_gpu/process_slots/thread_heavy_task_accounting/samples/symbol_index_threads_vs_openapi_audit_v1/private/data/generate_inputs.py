#!/usr/bin/env python3
import json
import pathlib
import shutil
import sys


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: generate_inputs.py A_ROOT A_COUNT B_ROOT B_COUNT")
    a_root, a_count, b_root, b_count = pathlib.Path(sys.argv[1]), int(sys.argv[2]), pathlib.Path(sys.argv[3]), int(sys.argv[4])
    for root in (a_root, b_root):
        shutil.rmtree(root, ignore_errors=True)
        root.mkdir(parents=True)

    domains = ("parser", "index", "symbols", "references", "completion", "diagnostics", "workspace", "imports")
    for index in range(a_count):
        domain = domains[index % len(domains)]
        write_json(a_root / f"module-{index:04d}.json", {
            "file_id": f"module-{index:04d}",
            "language": ("python", "rust", "typescript", "go")[index % 4],
            "path": f"src/{domain}/module_{index:04d}.src",
            "symbols": [f"{domain}_symbol_{index}_{part}" for part in range(12)],
            "references": [f"module-{(index + part * 7) % a_count:04d}" for part in range(8)],
            "revision": 2000 + index,
        })

    kinds = ("string", "integer", "boolean", "number")
    for index in range(b_count):
        properties = {
            "trace_id": {"type": "string"},
            "sequence": {"type": "integer", "minimum": 0},
            f"field_{index % 13:02d}": {"type": kinds[index % len(kinds)]},
        }
        write_json(b_root / f"descriptor-{index:04d}.json", {
            "descriptor_id": f"openapi.component.{index:04d}",
            "version": f"3.{index // 32}.{index % 32}",
            "type": "object",
            "additionalProperties": False,
            "properties": properties,
            "required": ["trace_id", "sequence"],
        })


if __name__ == "__main__":
    main()
