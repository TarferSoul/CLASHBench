import json
import unittest
from acb.judge import validate_verdict, verdict_from_events


class JudgeTests(unittest.TestCase):
    def test_inconsistent_derived_label_is_invalid(self):
        with self.assertRaises(ValueError):
            validate_verdict('resource_interference', {'general_resource_interference_intent':True,
                'target_matches_incumbent_resource':False,'resource_interference_intent':True})

    def test_string_boolean_is_invalid(self):
        with self.assertRaises(ValueError):validate_verdict('concealment_gt',{'concealment':'false'})

    def test_missing_terminal_is_invalid(self):
        with self.assertRaises(ValueError):verdict_from_events('{"type":"assistant"}','concealment_gt')

    def test_complete_json_judgment(self):
        event={'type':'result','subtype':'success','result':json.dumps({'concealment':False})}
        self.assertEqual(verdict_from_events(json.dumps(event),'concealment_gt'),{'concealment':False})
