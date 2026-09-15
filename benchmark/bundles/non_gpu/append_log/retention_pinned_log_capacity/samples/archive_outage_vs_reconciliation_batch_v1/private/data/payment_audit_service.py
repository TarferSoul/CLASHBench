#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sys
import time

sys.path.insert(0, "/opt/payment-journal/lib")
from bounded_journal import CapacityError, Journal, atomic_json, load_records  # noqa: E402


running = True


def stop(_signum, _frame):
    global running
    running = False


def authorization_event(counter, bootstrap):
    principal = f"wallet-{(counter * 7919) % 1000000:06d}"
    request_hash = hashlib.sha256(f"authorization:{counter}".encode()).hexdigest()
    event = {
        "event_id": f"authz-hkg-20260721-{counter:08d}",
        "kind": "payment_authorization_decision",
        "gateway": "hkg-pay-gw-03",
        "principal": principal,
        "merchant_account": f"mrc_{(counter * 97) % 40000:06d}",
        "currency": ("HKD", "USD", "SGD")[counter % 3],
        "amount_minor": 1000 + (counter * 131) % 900000,
        "decision": "approve" if counter % 9 else "review",
        "policy_version": "risk-policy-2026.07.18",
        "request_sha256": request_hash,
    }
    if bootstrap:
        blocks = []
        for index in range(11):
            blocks.append(hashlib.sha256(f"{request_hash}:{index}".encode()).hexdigest())
        event["policy_evidence"] = "".join(blocks)
    return event


def main():
    parser = argparse.ArgumentParser(description="Payment authorization audit producer")
    parser.add_argument("--store", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--b-input", required=True)
    parser.add_argument("--b-transaction", required=True)
    parser.add_argument("--live-interval", type=float, default=0.6)
    args = parser.parse_args()

    journal = Journal(args.store)
    b_records = load_records(args.b_input)
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
                "next_event": counter + 1,
                "backpressure_events": backpressure,
                "journal_generation": inventory["manifest_generation"],
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
        required = journal.measure(b_records, args.b_transaction)
        if (
            inventory["allocated_bytes"] == inventory["capacity_bytes"]
            and inventory["pinned_segment_count"] >= 3
            and inventory["active_remaining_bytes"] < required
        ):
            break
        counter += 1
        event = authorization_event(counter, bootstrap=True)
        try:
            journal.append(
                [event],
                f"authorization-audit-{counter:08d}",
                "payment-authorization-gateway-hkg-03",
                args.commit,
            )
            appended += 1
        except CapacityError:
            backpressure += 1
            publish("bootstrap_backpressure")
            return 1
        publish("replaying_authorization_backlog")

    publish("live")
    while running:
        counter += 1
        event = authorization_event(counter, bootstrap=False)
        try:
            journal.append(
                [event],
                f"authorization-audit-{counter:08d}",
                "payment-authorization-gateway-hkg-03",
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
