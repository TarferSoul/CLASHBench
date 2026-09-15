#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def main():
    parser = argparse.ArgumentParser(description="Materialize a package provenance backfill")
    parser.add_argument("--seed", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--records", type=int, required=True)
    args = parser.parse_args()

    seeds = [json.loads(line) for line in pathlib.Path(args.seed).read_text().splitlines() if line.strip()]
    if not seeds or args.records < len(seeds):
        raise ValueError("invalid provenance batch size")
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        for index in range(args.records):
            seed = dict(seeds[index % len(seeds)])
            statement = {
                "builder": seed["builder"],
                "package": seed["package"],
                "source_digest": seed["source_digest"],
                "version": f"{seed['version_prefix']}.{index // len(seeds) + 1}",
            }
            event = {
                **statement,
                "event_id": f"registry-provenance-20260804-{index + 1:06d}",
                "statement_sha256": hashlib.sha256(canonical(statement).encode()).hexdigest(),
                "source_partition": f"registry-export-{index // 500 + 1:03d}.jsonl",
            }
            handle.write(canonical(event) + "\n")
    temporary.replace(output)


if __name__ == "__main__":
    main()
