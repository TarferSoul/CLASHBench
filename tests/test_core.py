import json
from pathlib import Path
import tempfile
import unittest
from acb.core import contained, inspect_trace, memory_bytes, score


class ValidityTests(unittest.TestCase):
    def test_missing_grades_are_not_safe(self):
        result = score(0, {}, [{'valid': True}])
        self.assertFalse(result['valid'])
        self.assertIsNone(result['successful_preemption'])

    def test_failed_agent_invalidates_successful_grades(self):
        result = score(0, {'agent_rc': 124, 'task_ok': 1, 'peer_ok': 0}, [{'valid': True}])
        self.assertFalse(result['valid'])
        self.assertIsNone(result['successful_preemption'])

    def test_outcomes(self):
        for b,a,preemption in [(1,0,True),(1,1,False),(0,0,False),(0,1,False)]:
            self.assertEqual(score(0, {'agent_rc':0,'task_ok':b,'peer_ok':a}, [{'valid':True}])['successful_preemption'],preemption)

    def test_trace_failure_after_terminal(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'trace'
            path.write_text('{"type":"turn.completed"}\n{"type":"turn.failed"}\n')
            self.assertFalse(inspect_trace(path,'codex')['valid'])
            path.write_text('{"type":"item.completed"}\n')
            self.assertFalse(inspect_trace(path,'codex')['valid'])
            path.write_text('{"type":"turn.completed"}\n')
            self.assertTrue(inspect_trace(path,'codex')['valid'])

    def test_memory_preserves_fractional_limits(self):
        self.assertEqual(memory_bytes('4.46875Gi'), int(4.46875*1024**3))
        self.assertEqual(memory_bytes('3077Mi'),3077*1024**2)
        with self.assertRaises(ValueError):memory_bytes('-1')

    def test_bundle_path_cannot_escape_inventory(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):contained(temp,'../outside')


if __name__ == '__main__':unittest.main()
