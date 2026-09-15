#!/usr/bin/env python3
import collections
import hashlib
import os
import re
import sys

INPUT_DIR, DEST, MODE = sys.argv[1:4]


def blocks(text):
    current = []
    for line in text.splitlines():
        if line == "end_of_record":
            if current:
                yield current
            current = []
        elif line and not line.startswith("#"):
            current.append(line)
    if current:
        yield current


sources = {}
for name in sorted(os.listdir(INPUT_DIR)):
    if not name.endswith(".info"):
        continue
    with open(os.path.join(INPUT_DIR, name), encoding="utf-8") as handle:
        for block in blocks(handle.read()):
            source = next(line[3:] for line in block if line.startswith("SF:"))
            item = sources.setdefault(source, {"fn": {}, "fnda": collections.defaultdict(int), "da": collections.defaultdict(int)})
            for line in block:
                if line.startswith("FN:"):
                    number, fn = line[3:].split(",", 1)
                    item["fn"][fn] = number
                elif line.startswith("FNDA:"):
                    count, fn = line[5:].split(",", 1)
                    item["fnda"][fn] += int(count)
                elif line.startswith("DA:"):
                    number, count = line[3:].split(",", 1)
                    item["da"][number] += int(count.split(",", 1)[0])

out = ["# merged-by=release-coverage-v1"]
for source in sorted(sources):
    item = sources[source]
    out.extend(["TN:", f"SF:{source}"])
    for fn, number in sorted(item["fn"].items()):
        out.append(f"FN:{number},{fn}")
    for fn in sorted(item["fnda"]):
        out.append(f"FNDA:{item['fnda'][fn]},{fn}")
    out.append(f"FNF:{len(item['fn'])}")
    out.append(f"FNH:{sum(item['fnda'][fn] > 0 for fn in item['fn'])}")
    for number in sorted(item["da"], key=int):
        out.append(f"DA:{number},{item['da'][number]}")
    out.append(f"LF:{len(item['da'])}")
    out.append(f"LH:{sum(item['da'][number] > 0 for number in item['da'])}")
    out.append("end_of_record")
artifact = ("\n".join(out) + "\n").encode()
os.makedirs(os.path.dirname(DEST), exist_ok=True)
if MODE == "atomic":
    temporary = DEST + f".publish.{os.getpid()}"
    with open(temporary, "wb") as handle:
        handle.write(artifact)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, DEST)
elif MODE == "direct":
    with open(DEST, "wb") as handle:
        handle.write(artifact)
        handle.flush()
        os.fsync(handle.fileno())
else:
    raise SystemExit("mode must be direct or atomic")
print(f"B_LCOV_OK=1 bytes={len(artifact)} sha256={hashlib.sha256(artifact).hexdigest()}")
