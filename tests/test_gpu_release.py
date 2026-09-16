import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from clashbench.cli import asset_mounts, start
from clashbench.core import inventory

ROOT = Path(__file__).resolve().parents[1] / 'benchmark'


class GPUReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = inventory(ROOT / 'gpu-inventory.json')['cases']

    def test_complete_bundles_and_unchanged_task_surfaces(self):
        self.assertEqual(len(self.cases), 10)
        for case in self.cases:
            self.assertEqual((case['gpus'], case['cpus'], case['memory']), (1, 32, '64000Mi'))
            bundle = ROOT / case['bundle']
            files = {str(f.relative_to(bundle)) for f in bundle.rglob('*') if f.is_file()}
            self.assertEqual(files, set(case['sha256']))
            for name, expected in case['sha256'].items():
                self.assertEqual(hashlib.sha256((bundle / name).read_bytes()).hexdigest(), expected)
            sample = bundle / 'samples' / case['id']
            self.assertTrue((sample / 'public/prompts/task_query_p0_normal.txt').is_file())
            self.assertFalse((sample / 'private/data/agentic_safety_sft.json').exists())

    def test_runner_syntax_and_no_legacy_transport(self):
        for case in self.cases:
            bundle = ROOT / case['bundle']
            for script in bundle.rglob('*.sh'):
                subprocess.run(['bash', '-n', str(script)], check=True, capture_output=True)
            text = (bundle / case['runner']).read_text()
            for forbidden in ('HOST_PROXY_ROOT', 'HOST_CODEX', 'HOST_OPENCODE', '/mnt/', '9125', '9126', '9127'):
                self.assertNotIn(forbidden, text, case['id'])
            self.assertNotIn('"$RESULT_ROOT/evidence/result.json"', text)
            self.assertNotIn('$RESULT_ROOT/result.json:result.json', text)

    def test_native_harness_exit_and_evidence_contract(self):
        for case in self.cases:
            text = (ROOT / case['bundle'] / case['runner']).read_text()
            start = text.index('run_agent() {')
            function = text[start:text.index('\n}', start) + 2]
            for harness in ('codex', 'claude', 'opencode'):
                with tempfile.TemporaryDirectory() as tmp:
                    # Intercept only container-specific operations; run real shell redirections.
                    function = function.replace('< /work/TASK.txt', '< "$RESULT_ROOT/TASK.txt"')
                    script = '''set -euo pipefail
cd() { :; }
chown() { :; }
runuser() {
  printf '%s\\n' "$@" > "$RESULT_ROOT/argv"
  echo '{"type":"turn.completed"}'
  echo diagnostic >&2
  return 17
}
''' + function + '\nrun_agent\n'
                    Path(tmp, 'TASK.txt').write_text('Task')
                    subprocess.run(['bash', '-c', script], check=True, env=dict(
                        os.environ, RESULT_ROOT=tmp, B_CACHE_ROOT=tmp + '/cache', HARNESS=harness))
                    self.assertEqual(Path(tmp, 'agent_exit_code.txt').read_text().strip(), '17')
                    self.assertEqual(json.loads(Path(tmp, 'agent_trace.txt').read_text())['type'], 'turn.completed')
                    self.assertEqual(Path(tmp, 'B.err').read_text().strip(), 'diagnostic')
                    argv = Path(tmp, 'argv').read_text()
                    self.assertIn('/usr/local/bin/' + harness, argv)
                    self.assertIn('agentb', argv)

    def test_unavailable_oracle_fails_before_setup(self):
        unsupported = [c for c in self.cases if not c['oracle_supported']]
        self.assertEqual(len(unsupported), 3)
        for case in unsupported:
            result = subprocess.run(['bash', str(ROOT / case['bundle'] / case['runner'])],
                                    env=dict(os.environ, MODE='oracle'), capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('ORACLE_NOT_BUNDLED', result.stderr)

    def test_models_are_mapped_per_case(self):
        cases = {c['id']: c for c in self.cases}
        periodic = cases['periodic_eval_batch_vs_qwen35_export_v1']['environment']
        self.assertEqual(periodic['HOST_A_MODEL'], '/models/qwen4b')
        self.assertEqual(periodic['HOST_B_MODEL'], '/models/qwen35b')
        small = cases['qwen4b_quant_calibration_vs_training_smoke_v1']
        self.assertEqual([a['source_env'] for a in small['assets']], ['CLASHBENCH_QWEN4B_DIR'])

    def test_asset_errors_and_read_only_mount(self):
        case = {'id': 'test', 'assets': [{'source_env': 'CLASHBENCH_TEST_ASSET',
                'destination': '/models/test', 'required_files': ['config.json']}]}
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'set CLASHBENCH_TEST_ASSET'):
                asset_mounts(case)
            with tempfile.TemporaryDirectory() as tmp:
                os.environ['CLASHBENCH_TEST_ASSET'] = tmp
                with self.assertRaisesRegex(ValueError, 'missing config.json'):
                    asset_mounts(case)
                Path(tmp, 'config.json').write_text('{}')
                self.assertEqual(asset_mounts(case), [f'type=bind,src={tmp},dst=/models/test,readonly'])

    def test_gpu_only_start_inspects_only_gpu_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, 'inventory.json')
            path.write_text('{}')
            args = SimpleNamespace(inventory=str(path), config='unused', cases='all',
                mode='run', parallel=1, image='cpu', gpu_image='gpu', output=tmp,
                condition='default', keep_containers=False)
            case = {'id': 'gpu-test', 'gpus': 1}
            with patch('clashbench.cli.inventory', return_value={'cases': [case]}), \
                 patch('clashbench.cli.load_config', return_value={'harness': 'codex'}), \
                 patch('clashbench.cli.docker') as docker, \
                 patch('clashbench.cli.subprocess.Popen') as worker, patch('builtins.print'):
                worker.return_value.pid = 123
                start(args)
                docker.assert_called_once_with('image', 'inspect', 'gpu')
                worker.assert_called_once()


if __name__ == '__main__':
    unittest.main()
