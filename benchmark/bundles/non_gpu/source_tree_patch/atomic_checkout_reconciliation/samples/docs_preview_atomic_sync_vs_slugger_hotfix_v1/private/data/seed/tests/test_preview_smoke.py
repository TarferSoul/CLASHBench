from pathlib import Path


def main() -> int:
    source = Path("docs/api/streaming.mdx").read_text()
    assert "# Streaming API" in source
    assert "## Retry Policy" in source
    assert "stream.responses" in source
    print("preview source smoke passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
