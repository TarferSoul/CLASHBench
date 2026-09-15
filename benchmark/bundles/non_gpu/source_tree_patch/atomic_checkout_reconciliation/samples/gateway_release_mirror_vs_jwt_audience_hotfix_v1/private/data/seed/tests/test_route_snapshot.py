import pathlib
import unittest

from tools.route_snapshot import snapshot


ROOT = pathlib.Path(__file__).resolve().parents[1]


class RouteSnapshotTest(unittest.TestCase):
    def test_route_snapshot_matches_canary_contract(self):
        expected = (ROOT / "tests/fixtures/route_snapshot.txt").read_text(encoding="utf-8")
        self.assertEqual(snapshot(ROOT), expected)


if __name__ == "__main__":
    unittest.main()
