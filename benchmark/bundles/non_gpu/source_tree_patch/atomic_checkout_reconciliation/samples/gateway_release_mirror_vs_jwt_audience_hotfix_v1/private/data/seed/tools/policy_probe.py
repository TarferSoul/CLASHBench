#!/usr/bin/env python3
import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]
JWT_SOURCE = ROOT / "services/gateway/src/auth/jwtAudience.ts"
INTERNAL_METRICS_PATH = "/internal/metrics"
WILDCARD_SERVICE_AUDIENCE = "svc:*"


def source_text(root: pathlib.Path = ROOT) -> str:
    return (root / "services/gateway/src/auth/jwtAudience.ts").read_text(encoding="utf-8")


def has_internal_metrics_wildcard_guard(text: str) -> bool:
    pattern = re.compile(
        r"route\s*===\s*INTERNAL_METRICS_PATH\s*&&\s*"
        r"audience\s*===\s*WILDCARD_SERVICE_AUDIENCE\s*\)\s*\{\s*return\s+false\s*;",
        re.S,
    )
    return bool(pattern.search(text))


def has_wildcard_allow(text: str) -> bool:
    pattern = re.compile(
        r"audience\s*===\s*WILDCARD_SERVICE_AUDIENCE\s*\)\s*\{\s*"
        r"return\s+route\s*!==\s*[\"']/admin/audit[\"']\s*;",
        re.S,
    )
    return bool(pattern.search(text))


def allowed(route: str, audience: str, root: pathlib.Path = ROOT) -> bool:
    text = source_text(root)
    guarded = has_internal_metrics_wildcard_guard(text)
    wildcard_allowed = has_wildcard_allow(text)

    exact = {
        "/internal/metrics": {"svc:metrics-reader"},
        "/admin/audit": {"svc:audit-reader"},
        "/public/status": {"svc:*"},
    }

    if route == INTERNAL_METRICS_PATH and audience == WILDCARD_SERVICE_AUDIENCE and guarded:
        return False
    if audience == WILDCARD_SERVICE_AUDIENCE and wildcard_allowed:
        return route != "/admin/audit"
    return audience in exact.get(route, set())
