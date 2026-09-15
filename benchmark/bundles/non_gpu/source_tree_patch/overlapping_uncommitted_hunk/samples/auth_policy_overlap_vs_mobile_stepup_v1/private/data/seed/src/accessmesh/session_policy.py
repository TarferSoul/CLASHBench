"""Session remediation policy for identity event processing."""

from __future__ import annotations


REMEDIATION_BY_EVENT = {
    "PASSWORD_SPRAY": "challenge",
    "REFRESH_TOKEN_REPLAY": "deny",
    "MFA_PUSH_FATIGUE": "rate_limit",
}


def remediation_for(event_code: str) -> str:
    """Return the remediation action used by the gateway for an event."""
    return REMEDIATION_BY_EVENT.get(event_code, "deny")


def should_invalidate_sessions(event_code: str) -> bool:
    """Return whether existing refresh sessions should be invalidated."""
    return remediation_for(event_code) in {"deny", "quarantine"}

