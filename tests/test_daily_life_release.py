import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from clashbench.core import contained, inventory


ROOT = Path(__file__).resolve().parents[1] / 'benchmark'


class DailyLifeReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = inventory(ROOT / 'daily-life-inventory.json')

    def test_twenty_cases_have_complete_task_and_skill_surfaces(self):
        cases = self.data['cases']
        self.assertEqual(len(cases), 20)
        self.assertNotIn('dentist_followup_vs_client_meeting_v1', {c['id'] for c in cases})
        for case in cases:
            self.assertEqual(case['track'], 'daily-life')
            self.assertEqual((case['cpus'], case['memory'], case['gpus']), (4, '4Gi', 0))
            sample = contained(ROOT, case['bundle']) / 'samples' / case['id']
            manifest = json.loads((sample / 'manifest.json').read_text())
            self.assertEqual(manifest['id'], case['id'])
            for name in ['private/fixture.json', 'private/service.py',
                         'private/eval/oracle.sh', 'private/eval/grade_state.py',
                         'public/workload/tool.py', 'public/workload/HARNESS_INSTRUCTIONS.md',
                         'public/skills/' + manifest['surface']['agent_skill'] + '/SKILL.md']:
                self.assertTrue((sample / name).is_file(), str(sample / name))
            prompts = sample / 'public/prompts'
            self.assertEqual((prompts / 'task_query_p0_normal.txt').read_bytes(),
                             (prompts / 'task_query_p4_kill_authorized.txt').read_bytes())

    def test_hashes_and_unchanged_original_grading(self):
        first = self.data['cases'][0]
        bundle = contained(ROOT, first['bundle'])
        actual = {str(f.relative_to(bundle)): hashlib.sha256(f.read_bytes()).hexdigest()
                  for f in bundle.rglob('*') if f.is_file()}
        for case in self.data['cases']:
            self.assertEqual(case['sha256'], actual)
        for name, digest in actual.items():
            if name != first['runner']:
                self.assertEqual(digest, self.data['source_sha256'][name], name)
        for script in bundle.rglob('*.sh'):
            subprocess.run(['bash', '-n', str(script)], check=True, capture_output=True)

    def test_native_harness_adapter_and_exit_code(self):
        case = self.data['cases'][0]
        text = (ROOT / case['bundle'] / case['runner']).read_text()
        start = text.index('run_harness() {')
        function = text[start:text.index('\n}', start) + 2]
        function = function.replace('< /work/TASK.txt', '< "$TEST_ROOT/TASK.txt"')
        for harness in ('codex', 'claude', 'opencode'):
            with tempfile.TemporaryDirectory() as tmp:
                Path(tmp, 'TASK.txt').write_text('User task')
                script = '''set -euo pipefail
cd() { :; }
getent() { echo 'agentb:x:1000:1000::/home/agentb:/bin/bash'; }
runuser() {
  printf '%s\\n' "$@" > "$TEST_ROOT/argv"
  cat > "$TEST_ROOT/task"
  echo '{"type":"turn.completed"}'
  echo diagnostic >&2
  return 17
}
''' + function + '\nrun_harness\n'
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                    env=dict(os.environ, TEST_ROOT=tmp, HARNESS=harness, AGENT_USER='agentb',
                             FIXED_PATH='/usr/local/bin:/usr/bin:/bin'))
                self.assertEqual(result.returncode, 17)
                self.assertEqual(json.loads(result.stdout)['type'], 'turn.completed')
                self.assertEqual(result.stderr.strip(), 'diagnostic')
                self.assertEqual(Path(tmp, 'task').read_text(), 'User task')
                argv = Path(tmp, 'argv').read_text().splitlines()
                self.assertEqual(argv[-3:], ['timeout', '900', '/usr/local/bin/' + harness])
                self.assertEqual(argv[:2], ['-u', 'agentb'])


if __name__ == '__main__':
    unittest.main()
