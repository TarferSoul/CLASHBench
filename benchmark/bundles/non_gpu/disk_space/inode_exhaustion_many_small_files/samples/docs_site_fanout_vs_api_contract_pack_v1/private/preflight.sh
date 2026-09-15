#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
for tool in bash python3 mount umount mountpoint setpriv df stat find sha256sum; do
  command -v "$tool" >/dev/null || { echo "PREFLIGHT_OK=0 missing=$tool"; exit 1; }
done
mountpoint -q "$VOLUME_ROOT"
python3 - "$VOLUME_ROOT" "$TMPFS_INODES" "$ROOT/data/$INPUT_SOURCE" "$B_REQUIRED_MODULES" <<'PY'
import json
import os
import sys

path, expected_inodes, spec_path, modules = sys.argv[1:]
stats = os.statvfs(path)
spec = json.load(open(spec_path))
if stats.f_files != int(expected_inodes):
    raise SystemExit(f"unexpected inode capacity {stats.f_files}")
if spec["required_modules"] != int(modules):
    raise SystemExit("fixture module mismatch")
if stats.f_bavail * stats.f_frsize < 32 * 1024 * 1024:
    raise SystemExit("insufficient initial byte headroom")
print(f"PREFLIGHT_OK=1 total_inodes={stats.f_files} free_inodes={stats.f_favail} free_bytes={stats.f_bavail * stats.f_frsize}")
PY
