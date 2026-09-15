#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"SCHEMA_PROBE_FAIL=1 {message}")


parser = argparse.ArgumentParser()
parser.add_argument("schema", choices=("old", "target"))
parser.add_argument("project", type=Path)
parser.add_argument("--require-columnar", action="store_true")
args = parser.parse_args()

manifest = json.loads((args.project / "package.json").read_text())
lock = json.loads((args.project / "package-lock.json").read_text())
declared = manifest.get("dependencies")
if not isinstance(declared, dict) or declared.get("@telemetry/telemetry-runtime") != "file:vendor/telemetry-runtime":
    fail("manifest_rule_runtime_mismatch")
if args.require_columnar and declared.get("@telemetry/columnar-reader") != "file:vendor/columnar-reader":
    fail("manifest_columnar_mismatch")

if args.schema == "old":
    if lock.get("lockfileVersion") != 1:
        fail(f"required=1 actual={lock.get('lockfileVersion')}")
    if "packages" in lock or not isinstance(lock.get("dependencies"), dict):
        fail("v1_dependencies_table_contract")
    locked = lock["dependencies"]
    for name, spec in declared.items():
        if name not in locked or locked[name].get("version") != spec:
            fail(f"v1_lock_entry_mismatch name={name}")
else:
    if lock.get("lockfileVersion") != 3:
        fail(f"required=3 actual={lock.get('lockfileVersion')}")
    if "dependencies" in lock or not isinstance(lock.get("packages"), dict):
        fail("v3_packages_table_contract")
    packages = lock["packages"]
    root_dependencies = packages.get("", {}).get("dependencies")
    if root_dependencies != declared:
        fail("v3_root_manifest_mismatch")
    for name in declared:
        if f"node_modules/{name}" not in packages:
            fail(f"v3_package_entry_missing name={name}")

columnar = int("@telemetry/columnar-reader" in declared)
print(f"SCHEMA_PROBE_OK=1 schema={lock['lockfileVersion']} columnar={columnar}")
