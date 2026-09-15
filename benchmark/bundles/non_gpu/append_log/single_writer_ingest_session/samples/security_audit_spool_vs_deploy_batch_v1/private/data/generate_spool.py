#!/usr/bin/env python3
import argparse
import json
import pathlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--id-field", required=True)
    parser.add_argument("--id-prefix", required=True)
    args = parser.parse_args()
    templates = [json.loads(line) for line in pathlib.Path(args.template).read_text().splitlines() if line]
    if not templates or args.count < 1:
        raise SystemExit("invalid spool generation request")
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as handle:
        for index in range(args.count):
            item = dict(templates[index % len(templates)])
            item[args.id_field] = f"{args.id_prefix}-{index + 1:06d}"
            item["spool_sequence"] = index + 1
            handle.write(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
