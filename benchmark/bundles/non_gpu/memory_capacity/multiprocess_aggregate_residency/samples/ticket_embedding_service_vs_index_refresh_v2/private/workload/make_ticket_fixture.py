#!/usr/bin/env python3
import argparse
import json
import pathlib

from build_ticket_index import semantic_checksum, stable_embedding


COMPONENTS = ["auth", "retrieval", "billing", "workflow", "sdk", "storage", "search", "routing"]
SEVERITIES = ["low", "normal", "high", "urgent"]
TEMPLATES = [
    "intermittent timeout in {component} path after batch {n}",
    "{component} worker returns stale status for tenant {tenant}",
    "regression report shows elevated latency for {component}",
    "classifier missed escalation signal in {component} queue",
    "support macro failed to attach trace for {component}",
    "duplicate event observed while indexing {component} tickets",
    "{component} retry budget exhausted during replay {n}",
    "embedding drift detected for {component} incident group",
]


def make_row(shard: int, index: int):
    component = COMPONENTS[(shard * 3 + index) % len(COMPONENTS)]
    severity = SEVERITIES[(shard + index * 2) % len(SEVERITIES)]
    tenant = f"t{(shard * 17 + index * 5) % 97:02d}"
    n = shard * 1000 + index
    title = TEMPLATES[(shard + index) % len(TEMPLATES)].format(component=component, tenant=tenant, n=n)
    body = (
        f"ticket shard={shard} row={index} component={component} severity={severity} "
        f"tenant={tenant} includes logs, stack context, reproduction notes, and classifier labels "
        f"for deterministic offline embedding refresh batch {n}."
    )
    return {
        "ticket_id": f"TCK-{shard:02d}-{index:04d}",
        "component": component,
        "severity": severity,
        "title": title,
        "body": body,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--shards", type=int, default=4)
    parser.add_argument("--rows-per-shard", type=int, default=64)
    parser.add_argument("--dims", type=int, default=24)
    parser.add_argument("--resident-mib", type=int, default=550)
    parser.add_argument("--guard-mib", type=int, default=128)
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    ticket_dir = root / "tickets"
    ticket_dir.mkdir(parents=True, exist_ok=True)
    all_rows = []
    shard_paths = []
    row_counts = []
    for shard in range(args.shards):
        rows = [make_row(shard, index) for index in range(args.rows_per_shard)]
        path = ticket_dir / f"ticket_shard_{shard}.jsonl"
        with path.open("w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, sort_keys=True) + "\n")
        shard_paths.append(str(path))
        row_counts.append(len(rows))
        all_rows.extend(rows)

    checksum = semantic_checksum((row, stable_embedding(row, args.dims)) for row in all_rows)
    job = {
        "schema": "support-ticket-index-job-v1",
        "shards": shard_paths,
        "required_worker_count": args.shards,
        "expected_shard_row_counts": row_counts,
        "expected_total_rows": len(all_rows),
        "embedding_dimensions": args.dims,
        "resident_mib_per_worker": args.resident_mib,
        "admission_guard_mib": args.guard_mib,
        "expected_semantic_checksum": checksum,
        "required_outputs": ["embeddings.npy", "ticket_index.faiss", "index_manifest.json"],
    }
    pathlib.Path(args.job).write_text(json.dumps(job, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(f"TICKET_FIXTURE_OK rows={len(all_rows)} checksum={checksum}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

