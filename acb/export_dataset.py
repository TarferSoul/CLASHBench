"""Package selected frozen system-resource bundles for the Docker runner.

This is a local maintainer command; it never uploads data or changes its source.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil
from .core import atomic_json, contained


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', required=True, help='Frozen dataset directory with index/samples.tsv')
    p.add_argument('--output', required=True, help='New output directory (must not exist)')
    p.add_argument('--cases', default='all')
    args = p.parse_args()
    source, output = Path(args.source).resolve(), Path(args.output).resolve()
    if output.exists() or output.is_relative_to(source):
        p.error('Use a new output directory outside the immutable source dataset')
    rows = list(csv.DictReader((source / 'index/samples.tsv').open(), delimiter='\t'))
    selected = rows if args.cases == 'all' else [r for r in rows if r['sample_id'] in args.cases.split(',')]
    if not selected or (args.cases != 'all' and {r['sample_id'] for r in selected} != set(args.cases.split(','))):
        p.error('Unknown/empty case selection')
    output.mkdir(parents=True)
    cases = []
    for row in selected:
        relative = row['bundle']
        bundle = contained(source, relative)
        dest = contained(output, relative)
        if not dest.exists():
            for entry in bundle.rglob('*'):
                if entry.is_symlink() and not entry.resolve().is_relative_to(bundle):
                    raise ValueError('External bundle symlink: ' + str(entry))
            shutil.copytree(bundle, dest, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.git'))
        checksums = {str(f.relative_to(dest)): hashlib.sha256(f.read_bytes()).hexdigest()
                     for f in dest.rglob('*') if f.is_file()}
        cases.append({'id': row['sample_id'], 'track': 'system-resource', 'bundle': relative,
                      'runner': 'bin/run_case.sh', 'cpus': float(row['cpu']), 'memory': row['memory'],
                      'gpus': int(row.get('gpu_count') or 0), 'timeout_seconds': int(row['test_timeout_seconds']),
                      'resource': row['resource'], 'occupancy_configuration': row['profile'], 'sha256': checksums})
    atomic_json(output / 'inventory.json', {'schema_version': 1, 'dataset': 'AgentConflictBench-system-resources', 'cases': cases})
    print(json.dumps({'inventory': str(output / 'inventory.json'), 'cases': len(cases)}))


if __name__ == '__main__':
    main()
