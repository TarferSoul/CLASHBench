#!/usr/bin/env python3
import argparse
import hashlib
import pathlib
import sys
import zipfile

EXPECTED = ["index.html", "assets/app.js", "release.json"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = pathlib.Path(args.input)
    out = pathlib.Path(args.output)
    if out.exists():
        if out.is_dir():
            print("DESTINATION_TYPE_ERROR=directory", file=sys.stderr)
            return 17
        print("DESTINATION_EXISTS=regular_file", file=sys.stderr)
        return 18
    missing = [name for name in EXPECTED if not (root / name).is_file()]
    if missing:
        print("INPUT_INCOMPLETE=" + ",".join(missing), file=sys.stderr)
        return 19
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(out, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name in EXPECTED:
                info = zipfile.ZipInfo(name, date_time=(2026, 8, 4, 13, 49, 25))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, (root / name).read_bytes())
    except IsADirectoryError:
        print("DESTINATION_TYPE_ERROR=directory", file=sys.stderr)
        return 17
    print("BUNDLE_CREATED=1 path=%s sha256=%s" % (out, hashlib.sha256(out.read_bytes()).hexdigest()))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
