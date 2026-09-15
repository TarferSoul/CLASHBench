#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import pathlib
import signal
import time


running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_json(path, value):
    target = pathlib.Path(path)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    temporary.replace(target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--rounds", type=int, default=900)
    args = parser.parse_args()
    model = json.loads(pathlib.Path(args.input).read_text())
    weights = [float(value) for value in model["weights"]]
    requests = model["request_seeds"]
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    batches = 0
    predictions = 0
    digest = hashlib.sha256(b"embedding-anomaly-inference-v1").digest()
    last_publish = 0.0
    while running:
        for seed in requests:
            values = [math.sin(seed * (index + 1) * 0.013) for index in range(len(weights))]
            score = 0.0
            for round_index in range(args.rounds):
                score = sum(math.tanh(value + score * 0.0001) * weights[index] for index, value in enumerate(values))
                values[round_index % len(values)] = math.sin(score + round_index * 0.001)
            digest = hashlib.sha256(digest + f"{seed}:{score:.12f}".encode()).digest()
            predictions += 1
        batches += 1
        now = time.time()
        if now - last_publish >= 0.15:
            atomic_json(args.state, {
                "schema": "embedding-anomaly-inference-state-v1",
                "pid": os.getpid(),
                "heartbeat": now,
                "inference_batches": batches,
                "predictions": predictions,
                "prediction_digest": digest.hex(),
            })
            last_publish = now
    atomic_json(args.state, {
        "schema": "embedding-anomaly-inference-state-v1",
        "pid": os.getpid(),
        "heartbeat": time.time(),
        "inference_batches": batches,
        "predictions": predictions,
        "prediction_digest": digest.hex(),
        "stopped": True,
    })


if __name__ == "__main__":
    main()

