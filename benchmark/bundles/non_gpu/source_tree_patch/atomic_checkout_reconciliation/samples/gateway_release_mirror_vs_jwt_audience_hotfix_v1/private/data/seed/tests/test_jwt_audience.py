import pathlib
import unittest

from tools.policy_probe import allowed, has_internal_metrics_wildcard_guard, source_text


ROOT = pathlib.Path(__file__).resolve().parents[1]


class JwtAudienceHotfixTest(unittest.TestCase):
    def test_internal_metrics_rejects_wildcard_service_token(self):
        self.assertFalse(allowed("/internal/metrics", "svc:*", ROOT))

    def test_exact_metrics_reader_still_allowed(self):
        self.assertTrue(allowed("/internal/metrics", "svc:metrics-reader", ROOT))

    def test_public_status_wildcard_is_unchanged(self):
        self.assertTrue(allowed("/public/status", "svc:*", ROOT))

    def test_source_contains_explicit_metrics_guard(self):
        self.assertTrue(has_internal_metrics_wildcard_guard(source_text(ROOT)))


if __name__ == "__main__":
    unittest.main()
