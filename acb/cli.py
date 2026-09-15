"""Host controller: create -> copy -> start -> collect, using Docker only."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
from .core import atomic_json, contained, inspect_trace, inventory, memory_bytes, score

ROOT = Path(__file__).resolve().parents[1]


def docker(*args, timeout=60):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()


def load_config(path, require_credentials=True):
    cfg = json.loads(Path(path).read_text())
    if cfg.get('harness') not in ('codex', 'claude', 'opencode', 'smoke'):
        raise ValueError('Unknown harness')
    if cfg['harness'] != 'smoke':
        for key in ('model', 'base_url', 'api_key_env'):
            if not cfg.get(key):
                raise ValueError(f'Missing configuration field: {key}')
        if not cfg['base_url'].startswith(('http://', 'https://')):
            raise ValueError('base_url must be an HTTP(S) URL')
        if require_credentials and cfg['model'] == 'YOUR_MODEL':
            raise ValueError('Set model to the provider model ID first')
        if require_credentials and not os.environ.get(cfg['api_key_env']):
            raise ValueError('Set credential environment variable ' + cfg['api_key_env'])
    if 'api_key' in cfg:
        raise ValueError('Use api_key_env; do not store a literal key in a model config')
    return cfg


def start(args):
    path = Path(args.inventory).resolve()
    data = inventory(path)
    config = load_config(args.config, require_credentials=args.mode != 'oracle')
    selected = data['cases'] if args.cases == 'all' else [c for c in data['cases'] if c['id'] in args.cases.split(',')]
    if args.cases != 'all' and set(c['id'] for c in selected) != set(args.cases.split(',')):
        raise ValueError('Unknown case selection')
    if not selected or args.parallel < 1:
        raise ValueError('Select cases and a positive concurrency')
    if config['harness'] == 'smoke' and any(c.get('track') != 'smoke' for c in selected):
        raise ValueError('The smoke harness is restricted to smoke fixtures')
    if any(c.get('gpus', 0) for c in selected) and not args.gpu_image:
        raise ValueError('GPU cases require an explicitly prepared --gpu-image')
    for image in {args.image, *([args.gpu_image] if args.gpu_image else [])}:
        docker('image', 'inspect', image)
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    run = Path(args.output).resolve() / run_id
    run.mkdir(parents=True, mode=0o700)
    plan = {'run_id': run_id, 'inventory': str(path), 'inventory_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'cases': selected, 'config': config, 'condition': args.condition, 'mode': args.mode,
            'image': args.image, 'gpu_image': args.gpu_image, 'parallel': args.parallel,
            'keep_containers': args.keep_containers}
    atomic_json(run / 'plan.json', plan)
    atomic_json(run / 'status.json', {'state': 'starting', 'cases': len(selected)})
    env = dict(os.environ)
    env['PYTHONPATH'] = str(ROOT) + os.pathsep + env.get('PYTHONPATH', '')
    with (run / 'controller.log').open('wb') as log:
        p = subprocess.Popen([sys.executable, '-m', 'acb.cli', '_worker', str(run)],
                             stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=env)
    atomic_json(run / 'controller.json', {'pid': p.pid, 'run_id': run_id})
    print(json.dumps({'run_id': run_id, 'directory': str(run), 'controller_pid': p.pid}, indent=2))


def collect_result(case_dir, plan, rc):
    artifact = case_dir / 'artifacts'
    raw_paths = list(artifact.rglob('result.json'))
    if plan['mode'] == 'oracle':
        return {'valid': False, 'mode': 'oracle', 'oracle_passed': rc == 0,
                'successful_preemption': None, 'note': 'Oracle runs are never model evaluations.'}
    raw = json.loads(raw_paths[0].read_text()) if len(raw_paths) == 1 else {}
    trace_paths = list(artifact.rglob('agent_trace.txt'))
    traces = [inspect_trace(p, plan['config']['harness']) for p in trace_paths]
    result = score(rc, raw, traces)
    result.update(trace_checks=traces, runner_exit_code=rc, smoke=plan['config']['harness'] == 'smoke')
    if result['smoke']:
        result['successful_preemption'] = None
    return result


def run_case(run, plan, case):
    if (run / 'STOP').exists():
        return
    out = run / case['id']
    out.mkdir(mode=0o700)
    name = 'acb-' + plan['run_id'].lower() + '-' + hashlib.sha256(case['id'].encode()).hexdigest()[:8]
    image = plan['gpu_image'] if case.get('gpus', 0) else plan['image']
    cid = None
    try:
        image_id = docker('image', 'inspect', '--format', '{{.Id}}', image)
        argv = ['create', '--name', name, '--label', 'org.agentconflictbench.run=' + plan['run_id'],
                '--cpus', str(case['cpus']), '--memory', str(memory_bytes(case['memory'])),
                '--memory-swap', str(memory_bytes(case['memory'])), '--shm-size', str(memory_bytes(case.get('shm_size', '1Gi')))]
        if case.get('pids_limit'):
            argv += ['--pids-limit', str(case['pids_limit'])]
        if case.get('gpus', 0):
            argv += ['--gpus', str(case['gpus'])]
        for capability in case.get('cap_add', []):
            argv += ['--cap-add', capability]
        if 'SYS_ADMIN' in case.get('cap_add', []):
            argv += ['--security-opt', 'apparmor=unconfined']
        # Only explicitly declared data assets are mounted, always read-only.
        for mount in case.get('assets', []):
            source = Path(os.environ[mount['source_env']]).resolve()
            destination = mount['destination']
            if not source.exists() or not destination.startswith('/models/'):
                raise ValueError('GPU assets must exist and mount under /models/')
            argv += ['--mount', f'type=bind,src={source},dst={destination},readonly']
        argv += [image]
        cid = docker(*argv)
        atomic_json(out / 'container.json', {'id': cid, 'name': name, 'image_id': image_id})
        cfg = dict(plan['config'], condition=plan['condition'], mode=plan['mode'],
                   agent_timeout_seconds=max(1, int(case['timeout_seconds']) - 60))
        cfg['api_key'] = os.environ.get(cfg.get('api_key_env', ''), '')
        if cfg.get('proxy_env'):
            cfg['proxy_url'] = os.environ.get(cfg['proxy_env'], '')
            cfg['proxy_no_proxy'] = os.environ.get('NO_PROXY', 'localhost,127.0.0.1')
        bundle = contained(Path(plan['inventory']).parent, case['bundle'])
        with tempfile.TemporaryDirectory(prefix='acb-control-') as temp:
            tmp = Path(temp)
            atomic_json(tmp / 'config.json', cfg)
            (tmp / 'config.json').chmod(0o600)
            atomic_json(tmp / 'case.json', case)
            docker('cp', str(tmp) + '/.', cid + ':/run/acb-control')
        # docker cp copies a private bundle; the host dataset is never mounted writable.
        docker('cp', str(bundle), cid + ':/opt/acb-bundle', timeout=300)
        if (run / 'STOP').exists():
            raise RuntimeError('Run stopped before case launch')
        docker('start', cid)
        if (run / 'STOP').exists():
            docker('stop', '--time', '5', cid)
        atomic_json(out / 'status.json', {'state': 'running', 'container': cid})
        try:
            rc = int(docker('wait', cid, timeout=int(case['timeout_seconds'])))
        except subprocess.TimeoutExpired:
            docker('stop', '--time', '5', cid)
            rc = 124
        out_art = out / 'artifacts'
        out_art.mkdir()
        docker('cp', cid + ':/run/acb-results/.', str(out_art), timeout=300)
        logs = docker('logs', cid)
        # Redact known credentials even when a provider/tool writes one into output.
        secrets = [value for value in (cfg['api_key'], cfg.get('proxy_url')) if value]
        for secret in secrets:
            logs = logs.replace(secret, '[REDACTED]')
        (out / 'container.log').write_text(logs)
        if secrets:
            for p in out_art.rglob('*'):
                if p.is_file():
                    raw = p.read_bytes()
                    cleaned = raw
                    for secret in secrets:
                        cleaned = cleaned.replace(secret.encode(), b'[REDACTED]')
                    if cleaned != raw:
                        p.write_bytes(cleaned)
        result = collect_result(out, plan, rc)
        atomic_json(out / 'result.json', result)
        atomic_json(out / 'status.json', {'state': 'complete' if result['valid'] or result.get('oracle_passed') else 'invalid'})
    except Exception as exc:
        # Never serialize subprocess command arguments or credentials on failures.
        detail = getattr(exc, 'stderr', '') or str(exc)
        credential = os.environ.get(plan['config'].get('api_key_env', ''), '')
        if credential:
            detail = detail.replace(credential, '[REDACTED]')
        proxy = os.environ.get(plan['config'].get('proxy_env', ''), '')
        if proxy:
            detail = detail.replace(proxy, '[REDACTED]')
        (out / 'error.log').write_text(detail)
        atomic_json(out / 'result.json', {'valid': False, 'invalid_reasons': [type(exc).__name__], 'successful_preemption': None})
        atomic_json(out / 'status.json', {'state': 'invalid', 'error_type': type(exc).__name__})
    finally:
        if cid and not plan['keep_containers']:
            try:
                docker('rm', '-f', cid)
            except Exception:
                pass


def worker(run):
    run = Path(run)
    plan = json.loads((run / 'plan.json').read_text())
    atomic_json(run / 'status.json', {'state': 'running', 'cases': len(plan['cases'])})
    with ThreadPoolExecutor(max_workers=plan['parallel']) as pool:
        list(pool.map(lambda case: run_case(run, plan, case), plan['cases']))
    summarize(run)
    atomic_json(run / 'status.json', {'state': 'stopped' if (run / 'STOP').exists() else 'finished', 'cases': len(plan['cases'])})


def summarize(run):
    run = Path(run)
    records = [json.loads(p.read_text()) for p in run.glob('*/result.json')]
    valid = [r for r in records if r.get('valid') and not r.get('smoke')]
    spr = sum(r['successful_preemption'] for r in valid)
    dir_records = []
    for p in run.glob('*/judge-resource_interference.json'):
        judge = json.loads(p.read_text())
        result = json.loads((p.parent / 'result.json').read_text())
        trace = p.parent / 'judge-input.txt'
        if result.get('valid') and not result.get('smoke') and trace.is_file() and judge.get('trace_sha256') == hashlib.sha256(trace.read_bytes()).hexdigest():
            label = judge.get('verdict', {}).get('resource_interference_intent')
            if type(label) is bool:
                dir_records.append(label)
    summary = {'completed': len(records), 'evaluation_valid': len(valid),
               'invalid_or_non_evaluation': len(records) - len(valid),
               'SPR': {'events': spr, 'denominator': len(valid), 'rate': spr / len(valid) if valid else None},
               'DIR': {'events': sum(dir_records), 'denominator': len(dir_records), 'rate': sum(dir_records) / len(dir_records) if dir_records else None}}
    atomic_json(run / 'summary.json', summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('list'); p.add_argument('--inventory', default=str(ROOT / 'benchmark/inventory.json'))
    p = sub.add_parser('run')
    p.add_argument('--inventory', default=str(ROOT / 'benchmark/inventory.json')); p.add_argument('--cases', default='all')
    p.add_argument('--config', required=True); p.add_argument('--image', default='ghcr.io/tarfersoul/clashbench:cpu')
    p.add_argument('--gpu-image'); p.add_argument('--parallel', type=int, default=1)
    p.add_argument('--condition', choices=['default', 'preservation', 'permission'], default='default')
    p.add_argument('--mode', choices=['run', 'oracle'], default='run')
    p.add_argument('--output', default='results'); p.add_argument('--keep-containers', action='store_true')
    for cmd in ('status', 'summarize', 'stop', '_worker'):
        p = sub.add_parser(cmd); p.add_argument('run_directory')
    args = parser.parse_args()
    try:
        if args.command == 'list':
            for c in inventory(args.inventory)['cases']:
                print(c['id'], c['cpus'], c['memory'], 'GPU=' + str(c.get('gpus', 0)))
        elif args.command == 'run':
            start(args)
        elif args.command == '_worker':
            worker(args.run_directory)
        elif args.command == 'status':
            run = Path(args.run_directory)
            print((run / 'status.json').read_text())
            for p in sorted(run.glob('*/status.json')):
                print(p.parent.name, p.read_text().strip())
        elif args.command == 'summarize':
            print(json.dumps(summarize(args.run_directory), indent=2))
        elif args.command == 'stop':
            run = Path(args.run_directory)
            plan = json.loads((run / 'plan.json').read_text())
            # Prevent queued cases from launching after a stop request.
            (run / 'STOP').touch()
            for p in run.glob('*/container.json'):
                cid = json.loads(p.read_text())['id']
                try:
                    label = docker('inspect', '--format', '{{index .Config.Labels "org.agentconflictbench.run"}}', cid)
                    if label == plan['run_id']:
                        docker('stop', '--time', '5', cid)
                except subprocess.CalledProcessError:
                    pass
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(2, f'{type(exc).__name__}: {exc if not isinstance(exc, subprocess.SubprocessError) else "Docker operation failed; check Docker access and image availability"}\n')


if __name__ == '__main__':
    main()
