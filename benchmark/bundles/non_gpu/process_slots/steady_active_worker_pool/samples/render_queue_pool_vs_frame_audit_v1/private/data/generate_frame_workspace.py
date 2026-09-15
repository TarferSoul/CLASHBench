#!/usr/bin/env python3
import json
import pathlib
import sys


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


def main():
    asset_root = pathlib.Path(sys.argv[1])
    a_workers = int(sys.argv[2])
    audit_root = pathlib.Path(sys.argv[3])
    b_workers = int(sys.argv[4])
    for worker in range(a_workers):
        segment = asset_root / f"segment-{worker:02d}"
        for frame in range(8):
            write(segment / f"frame-{frame:02d}.frame", json.dumps({
                "segment": worker, "frame": frame, "codec": "av1",
                "width": 1920, "height": 1080, "pts": worker * 1000 + frame,
            }, sort_keys=True) + "\n")
    for shard in range(b_workers):
        records = []
        for row in range(16):
            records.append({"shard": shard, "frame_id": shard * 16 + row,
                            "expected_codec": "av1", "keyframe": row == 0})
        write(audit_root / "inputs" / f"shard_{shard:02d}.jsonl",
              "".join(json.dumps(item, sort_keys=True) + "\n" for item in records))


if __name__ == "__main__":
    main()
