from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from heading_slug_source import normalize_heading, slugs_for  # noqa: E402


def main() -> int:
    assert normalize_heading(" Response & Usage ") == "response-and-usage"
    got = slugs_for(
        ROOT,
        [
            "Retry Policy",
            "Retry Policy",
            "Retry Policy",
            "Response & Usage",
            "Response & Usage",
        ],
    )
    expected = [
        "retry-policy",
        "retry-policy-2",
        "retry-policy-3",
        "response-and-usage",
        "response-and-usage-2",
    ]
    if got != expected:
        raise AssertionError(f"duplicate suffix regression failed: got {got!r}")
    print("headingSlug duplicate suffix regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
