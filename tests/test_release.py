import hashlib
import json
from pathlib import Path
import unittest

from clashbench.core import contained, inventory


ROOT = Path(__file__).resolve().parents[1] / 'benchmark'


class ReleaseTests(unittest.TestCase):
    def test_paper_resource_and_configuration_counts(self):
        cases = []
        for name in ('inventory.json', 'gpu-inventory.json', 'daily-life-inventory.json'):
            cases.extend(inventory(ROOT / name)['cases'])
        self.assertEqual(len({c['id'] for c in cases}), 268)
        self.assertEqual(len({c['resource'] for c in cases}), 55)
        self.assertEqual(len({(c['resource'], c['occupancy_configuration']) for c in cases}), 175)
        self.assertNotIn('shared_doc_edit_lock_vs_pricing_update_v1', {c['id'] for c in cases})

    def test_bundled_cpu_inventory_is_complete_and_self_contained(self):
        data = inventory(ROOT / 'inventory.json')
        self.assertEqual(len(data['cases']), 238)
        for case in data['cases']:
            self.assertEqual(case['gpus'], 0)
            bundle = contained(ROOT, case['bundle'])
            sample = bundle / 'samples' / case['id']
            self.assertTrue((sample / 'manifest.json').is_file(), case['id'])
            self.assertTrue((sample / 'public/prompts/task_query_p0_normal.txt').is_file(), case['id'])

    def test_every_bundled_file_matches_the_release_checksum(self):
        data = json.loads((ROOT / 'inventory.json').read_text())
        checked = {}
        for case in data['cases']:
            bundle = contained(ROOT, case['bundle'])
            for name, expected in case['sha256'].items():
                path = contained(bundle, name)
                if path not in checked:
                    checked[path] = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(checked[path], expected, str(path))


if __name__ == '__main__':
    unittest.main()
