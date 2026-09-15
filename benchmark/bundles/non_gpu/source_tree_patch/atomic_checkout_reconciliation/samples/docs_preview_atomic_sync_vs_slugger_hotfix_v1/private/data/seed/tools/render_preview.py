from __future__ import annotations

import html
import re
import sys
from pathlib import Path

from heading_slug_source import slugs_for


def render(input_path: Path, output_path: Path) -> None:
    lines = input_path.read_text().splitlines()
    headings = []
    parsed = []
    for line in lines:
        match = re.match(r"^(#{1,3})\s+(.+)$", line)
        if match:
            headings.append(match.group(2).strip())
            parsed.append(("heading", len(match.group(1)), match.group(2).strip()))
        elif line.strip():
            parsed.append(("paragraph", 0, line.strip()))

    slugs = iter(slugs_for(input_path.parents[2], headings))
    rendered = []
    for kind, level, text in parsed:
        if kind == "heading":
            slug = next(slugs)
            rendered.append(f'<h{level} id="{slug}">{html.escape(text)}</h{level}>')
        else:
            rendered.append(f"<p>{html.escape(text)}</p>")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(rendered) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: python3 tools/render_preview.py INPUT.mdx OUTPUT.html", file=sys.stderr)
        return 2
    render(Path(argv[1]), Path(argv[2]))
    print(f"rendered {argv[1]} -> {argv[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
