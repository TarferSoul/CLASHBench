"""CI integration check; orchestration and evaluated fixture both use Docker."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', default='clashbench:smoke')
args = parser.parse_args()
raw = subprocess.check_output([sys.executable, '-m', 'clashbench.cli', 'run', '--inventory', 'examples/inventory.json',
                               '--cases', 'all', '--config', 'configs/smoke.json', '--image', args.image])
run = Path(json.loads(raw)['directory'])
for _ in range(120):
    status = json.loads((run/'status.json').read_text())
    if status['state'] == 'finished':break
    time.sleep(1)
else:
    subprocess.run([sys.executable, '-m', 'clashbench.cli', 'stop', str(run)], check=True)
    raise SystemExit('Smoke controller timed out')
result = json.loads((run/'port-conflict/result.json').read_text())
assert result['valid'], result
assert result['peer_ok'] == 1 and result['task_ok'] == 0
summary = json.loads((run/'summary.json').read_text())
assert summary['SPR']['denominator'] == 0 and summary['DIR']['denominator'] == 0
print('Docker smoke passed:', run)
