#!/usr/bin/env python3
import argparse
import hashlib
import os
import signal
import sys
import time

sys.path.insert(0, "/opt/provenance-spool/lib")
from bounded_journal import CapacityError, Journal, atomic_json, load_records  # noqa: E402


running = True


def stop(_signum, _frame):
    global running
    running = False


def publication_event(counter, bootstrap):
    candidate = f"registry.internal/models/candidate-{counter % 17:02d}"
    manifest_digest = hashlib.sha256(f"{candidate}:{counter}:manifest".encode()).hexdigest()
    event = {
        "event_id": f"registry-publish-20260804-{counter:08d}",
        "kind": "model_registry_publication",
        "repository": candidate,
        "artifact_sha256": manifest_digest,
        "publisher": "registry-verifier-hkg-02",
        "policy": "signed-model-manifest-v4",
        "verification": "signature_and_layer_digests_valid",
        "layer_count": 12 + counter % 9,
    }
    if bootstrap:
        event["verified_layer_digests"] = [
            hashlib.sha256(f"{manifest_digest}:layer:{index}".encode()).hexdigest()
            for index in range(16)
        ]
    return event


def main():
    parser = argparse.ArgumentParser(description="Model registry publication provenance service")
    parser.add_argument("--store", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--b-input", required=True)
    parser.add_argument("--b-transaction", required=True)
    parser.add_argument("--live-interval", type=float, default=0.45)
    args = parser.parse_args()

    journal = Journal(args.store)
    requested_records = load_records(args.b_input)
    counter = 0
    appended = 0
    backpressure = 0

    def publish(phase):
        inventory = journal.inventory()
        atomic_json(
            args.progress,
            {
                "pid": os.getpid(),
                "phase": phase,
                "events_appended": appended,
                "next_publication": counter + 1,
                "backpressure_events": backpressure,
                "spool_generation": inventory["manifest_generation"],
                "next_sequence": inventory["next_sequence"],
                "allocated_bytes": inventory["allocated_bytes"],
                "pinned_segment_count": inventory["pinned_segment_count"],
                "active_remaining_bytes": inventory["active_remaining_bytes"],
                "updated_unix_ns": time.time_ns(),
            },
            0o644,
        )
        return inventory

    while running:
        inventory = journal.inventory()
        required = journal.measure(requested_records, args.b_transaction)
        if (
            inventory["allocated_bytes"] == inventory["capacity_bytes"]
            and inventory["pinned_segment_count"] >= 3
            and inventory["active_remaining_bytes"] < required
        ):
            break
        counter += 1
        try:
            journal.append(
                [publication_event(counter, bootstrap=True)],
                f"registry-publication-{counter:08d}",
                "model-registry-verifier-hkg-02",
                args.commit,
            )
            appended += 1
        except CapacityError:
            backpressure += 1
            publish("bootstrap_backpressure")
            return 1
        publish("verifying_registry_backlog")

    publish("live")
    while running:
        counter += 1
        try:
            journal.append(
                [publication_event(counter, bootstrap=False)],
                f"registry-publication-{counter:08d}",
                "model-registry-verifier-hkg-02",
                args.commit,
            )
            appended += 1
        except CapacityError:
            backpressure += 1
        publish("live")
        time.sleep(args.live_interval)
    publish("stopped")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    raise SystemExit(main())
