#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import time


INSTALL_KEYS = (
    "FEATURE_STORE_TOKEN",
    "FEATURE_STORE_TOKEN_EXPIRES_AT",
    "FEATURE_STORE_LEASE_ID",
    "FEATURE_STORE_AUDIENCE",
    "RECONCILE_GENERATION",
    "FEATURE_STORE_API_URL",
)


def parse_dotenv(path):
    values = {}
    duplicates = {}
    malformed = []
    path = pathlib.Path(path)
    if path.exists():
        for raw in path.read_text(errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                malformed.append(raw)
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip("'").strip('"')
            if key in values:
                duplicates[key] = duplicates.get(key, 1) + 1
            values[key] = value
    return values, duplicates, malformed


def write_dotenv(path, values):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered = []
    for key in (
        "FEATURE_STORE_TOKEN",
        "FEATURE_STORE_TOKEN_EXPIRES_AT",
        "FEATURE_STORE_LEASE_ID",
        "FEATURE_STORE_AUDIENCE",
        "RECONCILE_GENERATION",
        "FEATURE_STORE_API_URL",
        "FEATURE_EXPORT_BATCH_SIZE",
    ):
        if key in values:
            ordered.append((key, values[key]))
    for key in sorted(set(values) - {key for key, _ in ordered}):
        ordered.append((key, values[key]))
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text("".join(f"{key}={value}\n" for key, value in ordered), encoding="utf-8")
    os.chmod(tmp, 0o664)
    os.replace(tmp, path)


def show(args):
    values, duplicates, malformed = parse_dotenv(args.env)
    print(json.dumps({"values": values, "duplicates": duplicates, "malformed": malformed}, sort_keys=True, indent=2))


def install(args):
    current, _, _ = parse_dotenv(args.env)
    supplied, duplicates, malformed = parse_dotenv(args.credential)
    missing = [key for key in INSTALL_KEYS[:4] if not supplied.get(key)]
    if missing or malformed or any(key in duplicates for key in INSTALL_KEYS):
        raise SystemExit(f"credential file is not usable: missing={missing} duplicates={duplicates} malformed={malformed}")
    merged = dict(current)
    for key in INSTALL_KEYS:
        if key in supplied:
            merged[key] = supplied[key]
    merged.setdefault("FEATURE_EXPORT_BATCH_SIZE", "64")
    write_dotenv(args.env, merged)
    print(json.dumps({"installed": True, "env": args.env, "credential": args.credential, "lease_id": merged.get("FEATURE_STORE_LEASE_ID", "")}, sort_keys=True))


def set_values(args):
    values, _, _ = parse_dotenv(args.env)
    for assignment in args.assignment:
        if "=" not in assignment:
            raise SystemExit(f"expected KEY=VALUE assignment, got {assignment!r}")
        key, value = assignment.split("=", 1)
        values[key] = value
    write_dotenv(args.env, values)
    print(json.dumps({"updated": sorted(item.split("=", 1)[0] for item in args.assignment), "env": args.env}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    show_p = sub.add_parser("show")
    show_p.add_argument("--env", required=True)
    show_p.set_defaults(func=show)
    install_p = sub.add_parser("install")
    install_p.add_argument("--env", required=True)
    install_p.add_argument("--credential", required=True)
    install_p.set_defaults(func=install)
    set_p = sub.add_parser("set")
    set_p.add_argument("--env", required=True)
    set_p.add_argument("assignment", nargs="+")
    set_p.set_defaults(func=set_values)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
