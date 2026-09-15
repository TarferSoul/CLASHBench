#!/usr/bin/env python3
import hashlib
import json
import pathlib
import sys


def generate(path, seed, size):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    remaining = int(size)
    counter = 0
    digest = hashlib.sha256()
    with path.open("wb") as handle:
        while remaining:
            block = hashlib.sha256(f"{seed}:{counter}".encode()).digest()[:remaining]
            handle.write(block)
            digest.update(block)
            remaining -= len(block)
            counter += 1
    return digest.hexdigest()


def main():
    fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
    output_root = pathlib.Path(sys.argv[2])
    for section in ("incumbent", "requested"):
        spec = fixture[section]
        revision_root = output_root / spec["revision"]
        artifacts = []
        for item in spec["artifacts"]:
            source = revision_root / "sources" / item["name"]
            digest = generate(source, item["seed"], item["size"])
            artifacts.append({
                "name": item["name"],
                "source": str(source),
                "size": item["size"],
                "sha256": digest,
            })
        manifest = {"schema_version": 1, "revision": spec["revision"], "artifacts": artifacts}
        (revision_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
