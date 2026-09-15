#!/usr/bin/env python3
import json
import pathlib


def parse_lock(path):
    text = pathlib.Path(path).read_text()
    try:
        import tomllib

        data = tomllib.loads(text)
        return {pkg["name"]: str(pkg["version"]) for pkg in data.get("package", [])}
    except Exception:
        versions = {}
        current = {}
        for line in text.splitlines() + ["[[package]]"]:
            stripped = line.strip()
            if stripped == "[[package]]":
                if current.get("name") and current.get("version"):
                    versions[current["name"]] = current["version"]
                current = {}
            elif stripped.startswith("name = "):
                current["name"] = stripped.split("=", 1)[1].strip().strip('"')
            elif stripped.startswith("version = "):
                current["version"] = stripped.split("=", 1)[1].strip().strip('"')
        return versions


if __name__ == "__main__":
    print(json.dumps(parse_lock("uv.lock"), indent=2, sort_keys=True))
