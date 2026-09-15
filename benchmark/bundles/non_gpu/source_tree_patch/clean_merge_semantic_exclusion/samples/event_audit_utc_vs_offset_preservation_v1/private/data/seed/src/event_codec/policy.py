from __future__ import annotations

from datetime import datetime


def timestamp_for_event(value: str) -> str:
    """Validate an aware ISO-8601 timestamp and retain its source offset."""
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("occurred_at must include a timezone offset")
    return parsed.isoformat(timespec="seconds")
