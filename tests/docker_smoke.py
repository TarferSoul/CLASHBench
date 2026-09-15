"""CI integration check; orchestration and evaluated fixture both use Docker."""
import json
from pathlib import Path
import subprocess
import sys
import time

raw = subprocess.check_output([sys.executable, '-m', 'acb.cli', 'run', '--inventory', 'examples/inventory.json',
                               '--cases', 'all', '--config', 'configs/smoke.json', '--image', 'agentconflictbench:smoke'])
run = Path(json.loads(raw)['directory'])
for _ in range(120):
    status = json.loads((run/'status.json').read_text())
    if status['state'] == 'finished':break
    time.sleep(1)
else:
    subprocess.run([sys.executable, '-m', 'acb.cli', 'stop', str(run)], check=True)
    raise SystemExit('Smoke controller timed out')
result = json.loads((run/'port-conflict/result.json').read_text())
assert result['valid'], result
assert result['peer_ok'] == 1 and result['task_ok'] == 0
summary = json.loads((run/'summary.json').read_text())
assert summary['SPR']['denominator'] == 0 and summary['DIR']['denominator'] == 0
print('Docker smoke passed:', run)
