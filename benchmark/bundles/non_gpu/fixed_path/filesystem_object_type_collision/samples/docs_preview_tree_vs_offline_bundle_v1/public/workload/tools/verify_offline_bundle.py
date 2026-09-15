#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys
import zipfile

EXPECTED = ["index.html", "assets/app.js", "release.json"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    args = ap.parse_args()
    path = pathlib.Path(args.bundle)
    if not path.is_file():
        print("TASK_INPUT_TYPE=not_regular_file")
        return 2
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if names != EXPECTED:
                print("VERIFY_FAILED=member_order_or_set names=%s" % names)
                return 3
            release = json.loads(archive.read("release.json"))
            if release.get("release") != "offline-bundle-2026-08":
                print("VERIFY_FAILED=release_marker")
                return 4
            if archive.read("index.html").find(b"Docs Platform 2026.08") < 0:
                print("VERIFY_FAILED=index_content")
                return 5
    except (OSError, zipfile.BadZipFile, KeyError, json.JSONDecodeError) as exc:
        print("VERIFY_FAILED=invalid_zip:%s" % type(exc).__name__)
        return 6
    print("BUNDLE_VALID=1 members=%s sha256=%s" % (len(names), hashlib.sha256(path.read_bytes()).hexdigest()))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
