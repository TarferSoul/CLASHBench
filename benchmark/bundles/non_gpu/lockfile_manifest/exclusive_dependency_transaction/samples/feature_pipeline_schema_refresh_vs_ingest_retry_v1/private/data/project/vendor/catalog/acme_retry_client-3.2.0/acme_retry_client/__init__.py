from __future__ import annotations


def build_retry_plan(client: str, max_attempts: int = 5) -> dict:
    delays = []
    value = 0.1
    for _ in range(max_attempts):
        delays.append(round(value, 1))
        value *= 3
    return {
        "client": client,
        "version": "3.2.0",
        "max_attempts": max_attempts,
        "backoff": delays,
    }
