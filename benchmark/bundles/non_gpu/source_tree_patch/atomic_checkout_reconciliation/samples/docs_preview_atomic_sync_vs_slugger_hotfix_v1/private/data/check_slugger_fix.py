import re
import subprocess
import sys
from pathlib import Path


def run(root: Path, command: list[str]) -> None:
    subprocess.run(command, cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python3 check_slugger_fix.py CHECKOUT_ROOT", file=sys.stderr)
        return 2
    root = Path(argv[1])
    run(root, ["python3", "tests/test_heading_slug.py"])
    run(root, ["python3", "tools/render_preview.py", "docs/api/streaming.mdx", "build/api/streaming.html"])
    html = (root / "build" / "api" / "streaming.html").read_text()
    ids = re.findall(r'id="([^"]+)"', html)
    assert "retry-policy" in ids
    assert "retry-policy-2" in ids
    assert "retry-policy-3" in ids
    assert len(set(ids)) == len(ids), "rendered preview contains duplicate heading ids"
    print("slugger fix and preview output verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
