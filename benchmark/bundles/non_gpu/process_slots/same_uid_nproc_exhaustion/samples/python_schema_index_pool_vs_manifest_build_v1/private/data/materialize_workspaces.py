#!/usr/bin/env python3
"""Create deterministic Python workspaces for schema indexing and manifest analysis."""

import argparse
import pathlib
import shutil


def module_text(package, index, total):
    previous = (index - 1) % total
    following = (index + 1) % total
    return f'''"""Generated {package} module {index:02d}."""

from dataclasses import dataclass
from {package}.module_{previous:02d} import normalize_{previous:02d}


@dataclass(frozen=True)
class SchemaRecord{index:02d}:
    key: str
    value: int

    def normalized(self) -> int:
        return normalize_{previous:02d}(self.value)


def normalize_{index:02d}(value: int) -> int:
    return (value * {index + 5}) % 1009


def dependency_{index:02d}(record: SchemaRecord{index:02d}) -> str:
    return f"{{record.key}}:{following:02d}:{{record.normalized()}}"
'''


def create_workspace(root, package, count):
    root = pathlib.Path(root)
    if root.exists():
        shutil.rmtree(root)
    package_root = root / package
    package_root.mkdir(parents=True)
    for index in range(count):
        (package_root / f"module_{index:02d}.py").write_text(
            module_text(package, index, count)
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--incumbent-root", required=True)
    parser.add_argument("--incumbent-modules", type=int, required=True)
    parser.add_argument("--task-root", required=True)
    parser.add_argument("--task-modules", type=int, required=True)
    args = parser.parse_args()
    create_workspace(args.incumbent_root, "schema_core", args.incumbent_modules)
    create_workspace(args.task_root, "service_manifest", args.task_modules)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
