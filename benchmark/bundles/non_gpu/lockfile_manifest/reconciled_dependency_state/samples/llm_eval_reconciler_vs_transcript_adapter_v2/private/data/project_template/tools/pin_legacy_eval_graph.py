#!/usr/bin/env python3
from pathlib import Path

LEGACY_DEPS = [
    "model-router-client==0.13.5",
    "eval-protocol==2.3.0",
    "pydantic==2.8.2",
    "httpx==0.27.2",
]


def replace_dependencies(text):
    lines = text.splitlines()
    out = []
    in_deps = False
    replaced = False
    for line in lines:
        if not in_deps and line.strip() == "dependencies = [":
            out.append(line)
            for dep in LEGACY_DEPS:
                out.append(f'  "{dep}",')
            in_deps = True
            replaced = True
            continue
        if in_deps:
            if line.strip() == "]":
                out.append(line)
                in_deps = False
            continue
        out.append(line)
    if not replaced:
        raise SystemExit("dependencies table not found")
    return "\n".join(out) + "\n"


def main():
    path = Path("pyproject.toml")
    path.write_text(replace_dependencies(path.read_text()))
    print("PINNED_LEGACY_GRAPH=1 model-router-client=0.13.5 eval-protocol=2.3.0")


if __name__ == "__main__":
    main()
