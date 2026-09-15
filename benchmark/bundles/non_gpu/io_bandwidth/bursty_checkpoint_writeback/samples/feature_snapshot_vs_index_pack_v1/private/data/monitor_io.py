#!/usr/bin/env python3
import argparse, json, pathlib, re, subprocess, time
def diskstats():
    result = {}
    for line in pathlib.Path('/proc/diskstats').read_text().splitlines():
        fields = line.split()
        if len(fields) < 14: continue
        name = fields[2]
        if name.startswith(('loop', 'ram', 'fd')): continue
        values = [int(value) for value in fields[3:14]]
        result[name] = {'read_sectors': values[2], 'write_sectors': values[6], 'in_flight': values[8], 'io_ms': values[9], 'weighted_io_ms': values[10]}
    return result
def pressure():
    path = pathlib.Path('/proc/pressure/io'); text = path.read_text() if path.exists() else ''
    return {'text': text.strip(), 'total': sum(int(v) for v in re.findall(r'total=(\d+)', text))}
def proc_io(pid):
    if not pid: return {}
    try: return {k: int(v.strip()) for k, v in (line.split(':', 1) for line in pathlib.Path(f'/proc/{pid}/io').read_text().splitlines())}
    except (FileNotFoundError, PermissionError, ProcessLookupError): return {}
def cpu_snapshot():
    values = [int(v) for v in pathlib.Path('/proc/stat').read_text().splitlines()[0].split()[1:]]
    return {'total': sum(values), 'idle': values[3] + (values[4] if len(values) > 4 else 0)}
def mem_available():
    for line in pathlib.Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'): return int(line.split()[1]) * 1024
    return 0
def read_state(root):
    try: return json.loads((root / 'status.json').read_text())
    except (FileNotFoundError, json.JSONDecodeError): return {}
ap = argparse.ArgumentParser()
for name in ('label', 'summary', 'samples', 'stdout', 'stderr', 'a-root', 'a-pid-file'): ap.add_argument(f'--{name}', required=True)
ap.add_argument('--interval', type=float, default=0.01); ap.add_argument('--release-file'); ap.add_argument('command', nargs=argparse.REMAINDER); args = ap.parse_args()
command = args.command[1:] if args.command and args.command[0] == '--' else args.command
if not command: raise SystemExit('command must follow --')
a_root = pathlib.Path(args.a_root)
try: a_pid = int(pathlib.Path(args.a_pid_file).read_text().strip())
except (FileNotFoundError, ValueError): a_pid = None
start_disk, start_pressure, start_cpu, start_a_io = diskstats(), pressure(), cpu_snapshot(), proc_io(a_pid); started = time.monotonic(); observations = []
with open(args.stdout, 'w') as out, open(args.stderr, 'w') as err:
    child = subprocess.Popen(command, stdout=out, stderr=err)
    if args.release_file:
        release = pathlib.Path(args.release_file); release.parent.mkdir(parents=True, exist_ok=True); release.write_text(f'b_pid={child.pid}\n')
    while child.poll() is None:
        state = read_state(a_root)
        observations.append({'elapsed': time.monotonic() - started, 'disk': diskstats(), 'pressure_total': pressure()['total'], 'a_io': proc_io(a_pid), 'b_io': proc_io(child.pid), 'a_phase': state.get('phase'), 'a_snapshot_id': state.get('snapshot_id'), 'a_completed_snapshots': state.get('completed_snapshots'), 'mem_available': mem_available()})
        time.sleep(args.interval)
    rc = child.wait()
state = read_state(a_root); observations.append({'elapsed': time.monotonic() - started, 'disk': diskstats(), 'pressure_total': pressure()['total'], 'a_io': proc_io(a_pid), 'b_io': {}, 'a_phase': state.get('phase'), 'a_snapshot_id': state.get('snapshot_id'), 'a_completed_snapshots': state.get('completed_snapshots'), 'mem_available': mem_available()})
end_disk, end_pressure, end_cpu, end_a_io = diskstats(), pressure(), cpu_snapshot(), proc_io(a_pid); deltas = {}
for name in sorted(set(start_disk) & set(end_disk)): deltas[name] = {key: max(0, end_disk[name][key] - start_disk[name][key]) for key in ('read_sectors', 'write_sectors', 'io_ms', 'weighted_io_ms')}
primary = max(deltas, key=lambda n: deltas[n]['write_sectors'], default=None); primary_delta = deltas.get(primary, {}); max_inflight = max((v['in_flight'] for o in observations for v in o['disk'].values()), default=0); cpu_total = max(1, end_cpu['total'] - start_cpu['total']); cpu_idle = max(0, end_cpu['idle'] - start_cpu['idle'])
result = {'label': args.label, 'returncode': rc, 'elapsed': time.monotonic() - started, 'sample_interval_sec': args.interval, 'sample_count': len(observations), 'primary_device': primary, 'device_deltas': deltas, 'write_sectors_delta': primary_delta.get('write_sectors', 0), 'read_sectors_delta': primary_delta.get('read_sectors', 0), 'io_ms_delta': primary_delta.get('io_ms', 0), 'weighted_io_ms_delta': primary_delta.get('weighted_io_ms', 0), 'max_inflight': max_inflight, 'io_pressure_total_delta': max(0, end_pressure['total'] - start_pressure['total']), 'a_write_bytes_delta': max(0, end_a_io.get('write_bytes', 0) - start_a_io.get('write_bytes', 0)), 'a_read_bytes_delta': max(0, end_a_io.get('read_bytes', 0) - start_a_io.get('read_bytes', 0)), 'b_write_bytes_observed': max((o['b_io'].get('write_bytes', 0) for o in observations), default=0), 'b_read_bytes_observed': max((o['b_io'].get('read_bytes', 0) for o in observations), default=0), 'a_phases_observed': sorted({o['a_phase'] for o in observations if o['a_phase']}), 'a_snapshot_ids_observed': sorted({int(o['a_snapshot_id']) for o in observations if o['a_snapshot_id'] is not None}), 'cpu_busy_ratio': max(0.0, min(1.0, 1.0 - cpu_idle / cpu_total)), 'minimum_mem_available': min((o['mem_available'] for o in observations), default=0), 'pressure_before': start_pressure['text'], 'pressure_after': end_pressure['text']}
pathlib.Path(args.summary).write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
with open(args.samples, 'w') as handle:
    for observation in observations: handle.write(json.dumps(observation, sort_keys=True) + '\n')
print(json.dumps(result, sort_keys=True)); raise SystemExit(rc)
