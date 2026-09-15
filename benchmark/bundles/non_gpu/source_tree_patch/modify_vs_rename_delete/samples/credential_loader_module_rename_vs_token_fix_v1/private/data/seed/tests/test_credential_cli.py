import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from credential_cli import credential_id


class CredentialCliTests(unittest.TestCase):
    def test_current_mapping(self):
        self.assertEqual(credential_id({"token": "svc-current"}), "svc-current")

    def test_missing_token(self):
        self.assertEqual(credential_id({}), "")


if __name__ == "__main__":
    unittest.main()
