from pathlib import Path
import sys


FIXED_SOURCE = '''"use strict";

function normalizeHeading(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/`([^`]+)`/g, "$1")
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function createHeadingSlugger() {
  const counts = new Map();
  return function headingSlug(text) {
    const base = normalizeHeading(text) || "section";
    const next = (counts.get(base) || 0) + 1;
    counts.set(base, next);
    return next === 1 ? base : `${base}-${next}`;
  };
}

module.exports = {
  createHeadingSlugger,
  normalizeHeading,
};
'''


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python3 apply_slugger_fix.py CHECKOUT_ROOT", file=sys.stderr)
        return 2
    root = Path(argv[1])
    target = root / "packages" / "mdx-renderer" / "src" / "headingSlug.ts"
    target.write_text(FIXED_SOURCE)
    print(f"patched {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
