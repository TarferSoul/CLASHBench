#!/usr/bin/env python3
"""Atomically set one dotenv key while collapsing duplicate assignments."""

import os
import pathlib
import re
import sys
import tempfile

if len(sys.argv) != 4 or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", sys.argv[2]):
    raise SystemExit("usage: set_dotenv.py PATH KEY VALUE")
path, wanted, new_value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
rows, replaced = [], False
for number, raw in enumerate(path.read_text().splitlines(keepends=True), 1):
    stripped = raw.strip()
    body = stripped[7:].lstrip() if stripped.startswith("export ") else stripped
    key = None
    if body and not body.startswith("#"):
        if "=" not in body:
            raise SystemExit(f"invalid dotenv line {number}")
        key = body.split("=", 1)[0].strip()
    if key == wanted:
        if not replaced:
            rows.append(f"{wanted}={new_value}\n")
            replaced = True
    else:
        rows.append(raw if raw.endswith("\n") else raw + "\n")
if not replaced:
    rows.append(f"{wanted}={new_value}\n")
fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        handle.writelines(rows)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print(f"DOTENV_UPDATE_OK=1 key={wanted}")
