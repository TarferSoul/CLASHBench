#!/usr/bin/env python3
import argparse
import gzip
import hashlib
import io
import json
import pathlib
import tarfile


VERSION = "2.7.0"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    source = pathlib.Path(args.source)
    output = pathlib.Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    files = sorted(path for path in source.rglob("*.py") if path.is_file())
    if len(files) != 3:
        raise SystemExit(f"expected 3 source files, found {len(files)}")
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for path in files:
            data = path.read_bytes()
            info = tarfile.TarInfo(f"release-cli-{VERSION}/{path.relative_to(source)}")
            info.size = len(data)
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(data))
    tarball = output / f"release-cli-{VERSION}.tar.gz"
    with tarball.open("wb") as handle:
        with gzip.GzipFile(filename="", mode="wb", fileobj=handle, mtime=0) as compressed:
            compressed.write(raw.getvalue())
    digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
    (output / f"{tarball.name}.sha256").write_text(f"{digest}  {tarball.name}\n")
    provenance = {"schema": "release-provenance-v1", "version": VERSION, "source_files": len(files), "sha256": digest, "artifact": tarball.name}
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
