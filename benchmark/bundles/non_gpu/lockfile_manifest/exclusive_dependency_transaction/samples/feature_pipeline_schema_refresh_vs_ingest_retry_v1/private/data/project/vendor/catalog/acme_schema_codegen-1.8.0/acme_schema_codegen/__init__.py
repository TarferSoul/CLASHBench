from __future__ import annotations


def render_event_type(name: str, fields: dict[str, str]) -> str:
    lines = [f"class {name}:"]
    for field, annotation in fields.items():
        lines.append(f"    {field}: {annotation}")
    return "\n".join(lines) + "\n"
