"""Container-side setup. This module must never execute on the host."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
from .core import atomic_json, contained


def main():
    if not Path('/.dockerenv').exists() or os.geteuid() != 0:
        raise SystemExit('Run this entry point in a Docker container as root.')
    control = Path('/run/acb-control')
    config = json.loads((control / 'config.json').read_text())
    case = json.loads((control / 'case.json').read_text())
    out = Path('/run/acb-results')
    out.mkdir(mode=0o700, exist_ok=True)
    os.chmod('/opt/acb-bundle', 0o700)
    runtime = Path('/opt/acb-agent')
    runtime.mkdir(mode=0o755, exist_ok=True)
    agent_config = runtime / 'config.json'
    agent_config.write_text(json.dumps(config))
    # Credentials are available only to the evaluated identity inside its container.
    import pwd
    uid = pwd.getpwnam('agentb').pw_uid
    os.chown(agent_config, uid, -1)
    agent_config.chmod(0o600)
    native_logs = runtime / 'logs'
    native_logs.mkdir(mode=0o700, exist_ok=True)
    os.chown(native_logs, uid, -1)
    for relative, digest in case.get('sha256', {}).items():
        import hashlib
        if hashlib.sha256(contained('/opt/acb-bundle', relative).read_bytes()).hexdigest() != digest:
            raise SystemExit('Bundle checksum mismatch: ' + relative)
    runner = contained('/opt/acb-bundle', case.get('runner', 'bin/run_case.sh'))
    env = dict(os.environ)
    env.update(BENCHMARK_SANDBOX='1', CASE=case['id'], MODE=config['mode'],
               PROMPT='p4' if config['condition'] == 'permission' else 'p0',
               HARNESS='codex' if config['harness'] == 'smoke' else config['harness'],
               HOST_ARTIFACT_ROOT=str(out), FILE_LOCK_ARTIFACT_ROOT=str(out),
               EVAL_AGENT_MODEL=config['model'], AGENT_TIMEOUT_SECONDS=str(config['agent_timeout_seconds']))
    # GPU assets and case-specific locations are declared explicitly in the inventory.
    env.update(case.get('environment', {}))
    try:
        with (out / 'runner.stdout').open('wb') as stdout, (out / 'runner.stderr').open('wb') as stderr:
            rc = subprocess.run(['bash', str(runner)], env=env, stdout=stdout, stderr=stderr).returncode
        atomic_json(out / 'runner.json', {'exit_code': rc})
    finally:
        if native_logs.exists():
            shutil.copytree(native_logs, out / 'native-harness-logs', dirs_exist_ok=True)
        agent_config.unlink(missing_ok=True)
        (control / 'config.json').unlink(missing_ok=True)
    return rc


if __name__ == '__main__':
    sys.exit(main())
