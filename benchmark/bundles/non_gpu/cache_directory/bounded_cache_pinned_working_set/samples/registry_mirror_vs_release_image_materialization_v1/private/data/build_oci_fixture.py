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
            block = hashlib.sha256(f"oci:{seed}:{counter}".encode()).digest()[:remaining]
            handle.write(block)
            digest.update(block)
            remaining -= len(block)
            counter += 1
    return digest.hexdigest()


def image_digest(image, tag, layers):
    payload = "\n".join(
        [f"image:{image}:{tag}"]
        + [f"{item['name']}:{item['sha256']}:{item['size']}" for item in layers]
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def main():
    fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
    output_root = pathlib.Path(sys.argv[2])
    for section in ("incumbent", "requested"):
        spec = fixture[section]
        image_root = output_root / f"{spec['image']}-{spec['tag']}"
        layers = []
        for item in spec["layers"]:
            source = image_root / "sources" / item["name"]
            digest = generate(source, item["seed"], item["size"])
            layers.append({
                "name": item["name"],
                "source": str(source),
                "size": item["size"],
                "sha256": digest,
            })
        manifest = {
            "schema_version": 2,
            "image": spec["image"],
            "tag": spec["tag"],
            "layers": layers,
            "manifest_sha256": image_digest(spec["image"], spec["tag"], layers),
        }
        (image_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
