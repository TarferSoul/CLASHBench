#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
plan_path = pathlib.Path(sys.argv[1]); source = pathlib.Path(sys.argv[2]); plan = json.loads(plan_path.read_text()); source.mkdir(parents=True, exist_ok=True)
for old in source.glob("*.jsonl"): old.unlink()
records = []; shard_mb = int(plan["shard_mb"]); chunk_size = 1024 * 1024
for index, item in enumerate(plan["shards"]):
    path = source / item["path"]
    prefix = f'{{"doc_id":"shard-{index:02d}","text":"'
    suffix = '"}\n'
    line = (prefix + "d" * (1024 - len(prefix) - len(suffix)) + suffix).encode()
    block = line * (chunk_size // len(line)); hasher = hashlib.sha256()
    with open(path, "wb", buffering=0) as handle:
        for _ in range(shard_mb): handle.write(block); hasher.update(block)
        os.fdatasync(handle.fileno())
    records.append({"path": item["path"], "bytes": path.stat().st_size, "sha256": hasher.hexdigest()})
plan["shards"] = records; tmp = pathlib.Path(str(plan_path) + ".tmp"); tmp.write_text(json.dumps(plan, sort_keys=True, indent=2) + "\n"); os.replace(tmp, plan_path)
fd = os.open(source, os.O_RDONLY); os.fsync(fd); os.close(fd)
