import unittest

from event_codec import serialize_event


class ExistingSerializationTests(unittest.TestCase):
    def test_utc_timestamp_remains_utc(self):
        event = {
            "event_id": "audit-existing",
            "occurred_at": "2026-08-05T04:00:00+00:00",
            "payload": {},
        }
        self.assertIn(
            serialize_event(event)["occurred_at"],
            {"2026-08-05T04:00:00+00:00", "2026-08-05T04:00:00Z"},
        )

    def test_naive_timestamp_is_rejected(self):
        event = {
            "event_id": "audit-naive",
            "occurred_at": "2026-08-05T04:00:00",
            "payload": {},
        }
        with self.assertRaises(ValueError):
            serialize_event(event)


if __name__ == "__main__":
    unittest.main()
