"""Check the packaged environments without weights, task data, or a GPU."""
import importlib.metadata as metadata
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    import torch
    import causal_conv1d_cuda
    import llamafactory.cli
    assert torch.__version__ == '2.6.0+cu124', torch.__version__
    assert metadata.version('fla-core') == '0.4.2'
    assert metadata.version('causal-conv1d') == '1.6.2.post1'
    assert Path('/opt/llamafactory/examples/deepspeed/ds_z2_config.json').is_file()
    print('Training:', json.dumps({k: metadata.version(k) for k in
          ('torch', 'transformers', 'deepspeed', 'fla-core', 'causal-conv1d')}), flush=True)
    env = dict(os.environ)
    env.pop('PYTHONPATH', None)
    subprocess.run(['/opt/vllm/bin/python', '-c',
        'import torch,vllm,transformers; '
        'assert vllm.__version__ == "0.19.1"; '
        'assert torch.__version__.split("+")[0] == "2.10.0"; '
        'print("vLLM:", vllm.__version__, "torch:", torch.__version__, '
        '"CUDA:", torch.version.cuda, "transformers:", transformers.__version__)'],
        env=env, check=True, timeout=600)
    for cli, expected in [('codex', '0.154.0'), ('claude', '2.1.272'), ('opencode', '1.18.31')]:
        output = subprocess.check_output([
            f'/opt/harness/{cli}/node_modules/.bin/{cli}', '--version'],
            text=True, stderr=subprocess.STDOUT, timeout=60)
        assert expected in output, output
        print(cli + ': ' + output.strip(), flush=True)
    assert Path('/opt/acb-runtime/manifest.json').is_file()
    print('GPU runtime imports and harness checks passed; CUDA execution and cases require separate validation.')


if __name__ == '__main__':
    main()
