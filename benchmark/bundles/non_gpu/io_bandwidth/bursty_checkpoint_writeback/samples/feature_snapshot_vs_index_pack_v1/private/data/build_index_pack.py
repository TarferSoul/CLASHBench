#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
plan = json.loads(pathlib.Path(sys.argv[sys.argv.index("--plan") + 1]).read_text()); source = pathlib.Path(sys.argv[sys.argv.index("--source") + 1]); output = pathlib.Path(sys.argv[sys.argv.index("--output") + 1]); output.mkdir(parents=True, exist_ok=True); tmp = output / ".pack.tmp"
if tmp.exists():
    for item in sorted(tmp.rglob("*"), reverse=True):
        if item.is_file() or item.is_symlink(): item.unlink()
        elif item.is_dir(): item.rmdir()
    tmp.rmdir()
tmp.mkdir(); entries = []; total = 0
for index, shard in enumerate(plan["shards"]):
    src = source / pathlib.PurePosixPath(shard["path"]); dst = tmp / f"partition-{index:02d}.pack"; hasher = hashlib.sha256()
    with open(src, "rb") as inp, open(dst, "wb", buffering=0) as out:
        while True:
            data = inp.read(1024 * 1024)
            if not data: break
            transformed = data[::-1]; out.write(transformed); hasher.update(transformed); total += len(transformed)
        os.fdatasync(out.fileno())
    entries.append({"path": dst.name, "source": shard["path"], "bytes": dst.stat().st_size, "sha256": hasher.hexdigest()})
manifest = {"index_id": plan["index_id"], "complete": True, "files": entries, "total_bytes": total}; manifest_tmp = tmp / "index-manifest.json.tmp"; manifest_tmp.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n"); fd = os.open(manifest_tmp, os.O_RDONLY); os.fsync(fd); os.close(fd); os.replace(manifest_tmp, tmp / "index-manifest.json"); fd = os.open(tmp, os.O_RDONLY); os.fsync(fd); os.close(fd)
for old in output.glob("partition-*.pack"): old.unlink()
for item in tmp.glob("partition-*.pack"): os.replace(item, output / item.name)
os.replace(tmp / "index-manifest.json", output / "index-manifest.json"); fd = os.open(output, os.O_RDONLY); os.fsync(fd); os.close(fd)
