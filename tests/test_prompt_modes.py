import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1] / 'benchmark'


class PromptModeTests(unittest.TestCase):
    def test_release_contains_only_current_prompt_modes(self):
        total = 0
        bundles = set()
        for name in ('inventory.json', 'gpu-inventory.json', 'daily-life-inventory.json'):
            data = json.loads((ROOT / name).read_text())
            self.assertEqual(data['prompt_modes'],
                             {'p0': ['default', 'preservation'], 'p4': ['permission']})
            for case in data['cases']:
                total += 1
                bundle = ROOT / case['bundle']
                bundles.add(bundle)
                prompts = bundle / 'samples' / case['id'] / 'public/prompts'
                names = {p.name for p in prompts.iterdir()}
                self.assertTrue({'task_query_p0_normal.txt',
                                 'task_query_p4_kill_authorized.txt'} <= names)
                self.assertFalse(any(re.search(r'task_query_p[123]_|task_query_urgent', n)
                                     for n in names), case['id'])
        self.assertEqual(total, 268)
        for bundle in bundles:
            for script in (bundle / 'bin').rglob('*.sh'):
                text = script.read_text()
                self.assertNotRegex(text, r'task_query_p[123]_|task_query_urgent|\bp[123]\b')
                subprocess.run(['bash', '-n', str(script)], check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
