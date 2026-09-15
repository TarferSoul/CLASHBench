#!/usr/bin/env python3
"""Small structural dotenv parser and atomic single-key editor for the fixture."""

import os
import pathlib
import re
import sys
import tempfile

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parsed_lines(path):
    rows = []
    for number, raw in enumerate(path.read_text().splitlines(keepends=True), 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            rows.append((raw, None, None))
            continue
        body = stripped[7:].lstrip() if stripped.startswith("export ") else stripped
        if "=" not in body:
            raise ValueError(f"invalid dotenv line {number}")
        key, value = body.split("=", 1)
        key = key.strip()
        if not KEY_RE.fullmatch(key):
            raise ValueError(f"invalid dotenv key at line {number}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        rows.append((raw, key, value))
    return rows


def values(path):
    result = {}
    counts = {}
    for _, key, value in parsed_lines(path):
        if key is not None:
            result[key] = value
            counts[key] = counts.get(key, 0) + 1
    return result, counts


def assert_values(path, key, expected, preserved):
    effective, counts = values(path)
    if counts.get(key, 0) != 1 or effective.get(key) != expected:
        raise SystemExit(f"critical assignment mismatch key={key} count={counts.get(key, 0)}")
    for item in preserved:
        pkey, pvalue = item.split("=", 1)
        if counts.get(pkey, 0) != 1 or effective.get(pkey) != pvalue:
            raise SystemExit(f"preserved assignment mismatch key={pkey}")
    print(f"DOTENV_ASSERT_OK=1 key={key} assignments=1 preserved={len(preserved)}")


def atomic_set(path, key, value):
    rows = parsed_lines(path)
    replaced = False
    output = []
    for raw, row_key, _ in rows:
        if row_key == key:
            if not replaced:
                output.append(f"{key}={value}\n")
                replaced = True
            continue
        output.append(raw if raw.endswith("\n") else raw + "\n")
    if not replaced:
        output.append(f"{key}={value}\n")
    fd, name = tempfile.mkstemp(prefix=".runtime.env.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.writelines(output)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


command = sys.argv[1]
path = pathlib.Path(sys.argv[2])
if command == "assert":
    assert_values(path, sys.argv[3], sys.argv[4], sys.argv[5:])
elif command == "set":
    atomic_set(path, sys.argv[3], sys.argv[4])
    assert_values(path, sys.argv[3], sys.argv[4], sys.argv[5:])
else:
    raise SystemExit("usage: dotenv_tool.py assert|set PATH KEY VALUE [KEY=VALUE ...]")
