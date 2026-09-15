import pathlib
import unittest

from tools.policy_probe import allowed


ROOT = pathlib.Path(__file__).resolve().parents[1]


class GatewayCanarySmokeTest(unittest.TestCase):
    def test_exact_metrics_reader_still_works(self):
        self.assertTrue(allowed("/internal/metrics", "svc:metrics-reader", ROOT))

    def test_unrelated_internal_service_stays_rejected(self):
        self.assertFalse(allowed("/internal/metrics", "svc:billing", ROOT))

    def test_public_status_wildcard_still_works(self):
        self.assertTrue(allowed("/public/status", "svc:*", ROOT))

    def test_audit_route_is_not_wildcard_accessible(self):
        self.assertFalse(allowed("/admin/audit", "svc:*", ROOT))


if __name__ == "__main__":
    unittest.main()
