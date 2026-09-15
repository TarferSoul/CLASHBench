#!/usr/bin/env python3
import argparse
import base64
import csv
import hashlib
import io
import json
import pathlib
import re
import zipfile


def wheel_name(name, version):
    normalized = re.sub(r"[-_.]+", "_", name).lower()
    return f"{normalized}-{version}-py3-none-any.whl"


def dist_info_name(name, version):
    normalized = re.sub(r"[-_.]+", "_", name).lower()
    return f"{normalized}-{version}.dist-info"


def record_hash(data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("=")
    return f"sha256={digest}", str(len(data))


def make_metadata(package):
    lines = [
        "Metadata-Version: 2.1",
        f"Name: {package['name']}",
        f"Version: {package['version']}",
        f"Summary: {package.get('summary', 'local fixture package')}",
        "Requires-Python: >=3.8",
    ]
    for requirement in package.get("requires_dist", []):
        lines.append(f"Requires-Dist: {requirement}")
    return ("\n".join(lines) + "\n").encode()


def write_wheel(package, dest):
    dist_info = dist_info_name(package["name"], package["version"])
    entries = {}
    for path, content in package["files"].items():
        entries[path] = content.encode()
    entries[f"{dist_info}/METADATA"] = make_metadata(package)
    entries[f"{dist_info}/WHEEL"] = (
        "Wheel-Version: 1.0\n"
        "Generator: agentconflict-local-fixture\n"
        "Root-Is-Purelib: true\n"
        "Tag: py3-none-any\n"
    ).encode()
    entries[f"{dist_info}/top_level.txt"] = (package["top_level"] + "\n").encode()

    rows = []
    for path, data in entries.items():
        digest, size = record_hash(data)
        rows.append([path, digest, size])
    rows.append([f"{dist_info}/RECORD", "", ""])
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerows(rows)
    entries[f"{dist_info}/RECORD"] = buffer.getvalue().encode()

    output = dest / wheel_name(package["name"], package["version"])
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(entries):
            archive.writestr(path, entries[path])
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--dest", required=True)
    args = parser.parse_args()
    source = pathlib.Path(args.source)
    dest = pathlib.Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    for old in dest.glob("*.whl"):
        old.unlink()
    data = json.loads(source.read_text())
    outputs = [write_wheel(package, dest) for package in data["packages"]]
    for output in outputs:
        print(f"BUILT_WHEEL={output}")


if __name__ == "__main__":
    main()
