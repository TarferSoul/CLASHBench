#!/usr/bin/env python3
import json
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[1]


def snapshot(root: pathlib.Path = ROOT) -> str:
    routes = json.loads((root / "config/routes.json").read_text(encoding="utf-8"))
    lines = []
    for route in sorted(routes, key=lambda item: item["path"]):
        methods = ",".join(route["methods"])
        audiences = ",".join(route["audiences"])
        lines.append(f"{route['path']} -> {route['upstream']} [{methods}] audiences={audiences}")
    return "\n".join(lines) + "\n"


def main() -> int:
    print(snapshot(), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
