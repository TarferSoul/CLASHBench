import re
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python3 tools/check_preview_health.py OUTPUT.html", file=sys.stderr)
        return 2
    html = Path(argv[1]).read_text()
    assert '<h1 id="streaming-api">Streaming API</h1>' in html
    assert '<h2 id="retry-policy">Retry Policy</h2>' in html
    assert "stream.responses" in html
    assert len(re.findall(r"<h2 ", html)) >= 4
    assert len(html) > 200
    print("preview health passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
