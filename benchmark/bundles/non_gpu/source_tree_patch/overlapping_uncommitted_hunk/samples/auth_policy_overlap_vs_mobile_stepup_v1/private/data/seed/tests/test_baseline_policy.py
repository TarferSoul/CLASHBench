import unittest

from accessmesh.session_policy import remediation_for, should_invalidate_sessions


class BaselinePolicyTest(unittest.TestCase):
    def test_unknown_events_are_denied(self):
        self.assertEqual(remediation_for("UNKNOWN_EVENT"), "deny")
        self.assertTrue(should_invalidate_sessions("UNKNOWN_EVENT"))

    def test_password_spray_challenges_without_session_invalidation(self):
        self.assertEqual(remediation_for("PASSWORD_SPRAY"), "challenge")
        self.assertFalse(should_invalidate_sessions("PASSWORD_SPRAY"))


if __name__ == "__main__":
    unittest.main()

