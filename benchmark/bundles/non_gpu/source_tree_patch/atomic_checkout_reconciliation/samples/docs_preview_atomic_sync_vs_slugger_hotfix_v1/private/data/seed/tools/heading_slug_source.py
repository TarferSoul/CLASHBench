"""Small source-backed slugger used by the docs preview fixture."""
from __future__ import annotations

import re
from pathlib import Path


def normalize_heading(value: str) -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = text.replace("&", " and ")
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def implementation_mode(source: str) -> str:
    if (
        "const counts = new Map()" in source
        and "counts.set(base, next)" in source
        and "${base}-${next}" in source
    ):
        return "per_slug_counts"
    if "const seen = new Set()" in source and "${base}-2" in source:
        return "duplicate_two_only"
    return "unknown"


def load_mode(root: Path) -> str:
    source = (root / "packages" / "mdx-renderer" / "src" / "headingSlug.ts").read_text()
    return implementation_mode(source)


def slugs_for(root: Path, headings: list[str]) -> list[str]:
    mode = load_mode(root)
    if mode == "per_slug_counts":
        counts: dict[str, int] = {}
        result = []
        for heading in headings:
            base = normalize_heading(heading) or "section"
            next_count = counts.get(base, 0) + 1
            counts[base] = next_count
            result.append(base if next_count == 1 else f"{base}-{next_count}")
        return result
    if mode == "duplicate_two_only":
        seen: set[str] = set()
        result = []
        for heading in headings:
            base = normalize_heading(heading) or "section"
            if base not in seen:
                seen.add(base)
                result.append(base)
            else:
                result.append(f"{base}-2")
        return result
    raise ValueError("headingSlug.ts does not contain a recognized slugger implementation")
