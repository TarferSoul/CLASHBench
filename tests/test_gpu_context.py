import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'gpu_context', Path(__file__).resolve().parents[1] / 'docker/build_gpu_context.py')
gpu_context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpu_context)


class GPUContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lf, self.fast, self.vllm = [self.root / name for name in ('lf', 'fast', 'vllm')]
        self.write(self.lf / 'src/llamafactory/cli.py', '# current local training source\n')
        self.write(self.lf / '.env.local', 'PRIVATE_CONFIGURATION')
        self.write(self.lf / 'data/training.json', 'PRIVATE_TRAINING_DATA')
        self.write(self.lf / 'outputs/model.safetensors', 'MODEL_WEIGHTS')
        self.write(self.fast / 'causal_conv1d/__init__.py', '')
        self.write(self.fast / 'INSTALL_INFO.txt', '/original/cluster/path')
        self.write(self.fast / 'causal_conv1d/__pycache__/x.pyc', 'CACHE')
        site = self.vllm / 'lib/python3.11/site-packages'
        self.write(site / 'vllm-0.19.1.dist-info/METADATA', 'Version: 0.19.1\n')
        for name in ('python', 'python3', 'python3.11'):
            self.write(self.vllm / 'bin' / name, 'PYTHON_BINARY')
        self.write(self.vllm / 'bin/vllm', '#!/original/cluster/python\n')
        self.write(self.vllm / 'pyvenv.cfg', 'home = /original/cluster/path\n')

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    def build(self):
        binary = io.BytesIO()
        output = io.TextIOWrapper(binary)
        argv = ['build_gpu_context.py', '--llamafactory', str(self.lf),
                '--fastpath', str(self.fast), '--vllm', str(self.vllm)]
        with patch.object(gpu_context.sys, 'argv', argv), \
                patch.object(gpu_context.sys, 'stdout', output), \
                patch.object(gpu_context.sys, 'stderr', io.StringIO()), \
                patch.object(gpu_context.subprocess, 'check_output', side_effect=[
                    b'src/llamafactory/cli.py\0', b'0123456789abcdef\n']):
            gpu_context.main()
        output.flush()
        data = binary.getvalue()
        output.detach()
        return data

    def test_curated_archive_excludes_assets_and_relocates_venv(self):
        data = self.build()
        self.assertTrue(data.startswith(b'\x1f\x8b'))
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            names = archive.getnames()
            self.assertFalse(any('.env' in n or '__pycache__' in n or 'training.json' in n
                                 or 'model.safetensors' in n for n in names))
            self.assertNotIn('runtime/vllm/bin/vllm', names)
            cfg = archive.extractfile('runtime/vllm/pyvenv.cfg').read().decode()
            self.assertIn('home = /opt/conda/bin', cfg)
            self.assertNotIn('/original/cluster', cfg)
            manifest = json.load(archive.extractfile('runtime/manifest.json'))
            name = 'runtime/llamafactory/src/llamafactory/cli.py'
            self.assertEqual(manifest['files'][name]['sha256'], hashlib.sha256(
                archive.extractfile(name).read()).hexdigest())

    def test_external_runtime_symlink_is_rejected(self):
        (self.fast / 'causal_conv1d/private').symlink_to(self.lf / '.env.local')
        with self.assertRaisesRegex(ValueError, 'External symlink'):
            self.build()


if __name__ == '__main__':
    unittest.main()
