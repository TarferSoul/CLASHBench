from __future__ import annotations

from typing import Mapping

from .policy import timestamp_for_event


def serialize_event(event: Mapping[str, object]) -> dict[str, object]:
    """Return the stable representation published to replay consumers."""
    event_id = str(event.get("event_id", "")).strip()
    if not event_id:
        raise ValueError("event_id is required")
    occurred_at = str(event.get("occurred_at", "")).strip()
    return {
        "event_id": event_id,
        "occurred_at": timestamp_for_event(occurred_at),
        "payload": event.get("payload", {}),
    }
