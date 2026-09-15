#!/usr/bin/env python3
"""Build regional coverage summaries with stable read-only database sessions."""
import json
import multiprocessing as mp
import os
import pathlib
import signal
import time

import psycopg2

ACTIVE_CONNECTION = None
STOP = False

def atomic_json(path, payload):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + f'.{os.getpid()}.tmp')
    tmp.write_text(json.dumps(payload, sort_keys=True) + '\n')
    os.replace(tmp, path)

def request_stop(signum, frame):
    global STOP
    STOP = True
    if ACTIVE_CONNECTION is not None:
        try:
            ACTIVE_CONNECTION.cancel()
        except Exception:
            pass

def scan_region(config, region):
    global ACTIVE_CONNECTION
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    state_path = pathlib.Path(config['state_dir']) / f'partition_{region:02d}.json'
    output_path = pathlib.Path(config['output_dir']) / f'coverage_region_{region:02d}.csv'
    conn = None
    try:
        app = f"{config['application_prefix']}{region:02d}"
        conn = psycopg2.connect(host=config['socket'], dbname=config['database'], user=config['role'], application_name=app)
        ACTIVE_CONNECTION = conn
        conn.set_session(readonly=True, autocommit=True)
        state = {'generation': config['generation'], 'service_token': config['service_token'],
                 'partition': region, 'pid': os.getpid(), 'backend_pid': conn.get_backend_pid(),
                 'application_name': app, 'status': 'active', 'iterations': 0,
                 'bytes_written': 0, 'updated_at_epoch': time.time()}
        with output_path.open('w', encoding='utf-8', buffering=1) as handle:
            class ProgressSink:
                def write(self, data):
                    text = data.decode() if isinstance(data, bytes) else data
                    handle.write(text)
                    state['iterations'] += text.count('\n')
                    state['bytes_written'] = handle.tell()
                    state['updated_at_epoch'] = time.time()
                    atomic_json(state_path, state)
                    return len(data)
                def flush(self):
                    handle.flush()
            query=f"""
            COPY (
              SELECT {region} AS region_id, g AS window, stats.tiles, stats.area_km2,
                     stats.quality_sum, pg_sleep(0.12) AS page_wait
              FROM generate_series(1, {int(config['repeat_factor'])}) AS g
              CROSS JOIN LATERAL (
                SELECT count(*) AS tiles, coalesce(sum(area_km2),0) AS area_km2,
                       coalesce(sum(quality_score),0) AS quality_sum
                FROM {config['schema']}.coverage_tiles WHERE region_id={region}
              ) AS stats
            ) TO STDOUT WITH CSV HEADER
            """
            with conn.cursor() as cur:
                cur.copy_expert(query, ProgressSink())
        state['status'] = 'stopped' if STOP else 'complete'
        state['updated_at_epoch'] = time.time()
        atomic_json(state_path, state)
    except Exception as exc:
        atomic_json(state_path, {'generation': config['generation'], 'service_token': config['service_token'],
                                 'partition': region, 'pid': os.getpid(), 'status': 'error',
                                 'error': f'{type(exc).__name__}:{exc}', 'updated_at_epoch': time.time()})
        if not STOP:
            raise
    finally:
        ACTIVE_CONNECTION = None
        if conn is not None:
            conn.close()

def snapshot(config, workers, status):
    return {'generation': config['generation'], 'service_token': config['service_token'],
            'status': status, 'pid': os.getpid(),
            'worker_pids': {f'{region:02d}': proc.pid for region, proc in workers.items()},
            'alive_workers': sorted(f'{region:02d}' for region, proc in workers.items() if proc.is_alive()),
            'updated_at_epoch': time.time()}

def main():
    config = json.loads(pathlib.Path(os.environ.get('COHORT_REPORT_CONFIG', '/etc/coverage-report/config.json')).read_text())
    pathlib.Path(config['state_dir']).mkdir(parents=True, exist_ok=True)
    pathlib.Path(config['output_dir']).mkdir(parents=True, exist_ok=True)
    stop_file = pathlib.Path(config['stop_file']); stop_file.unlink(missing_ok=True)
    signal.signal(signal.SIGTERM, request_stop); signal.signal(signal.SIGINT, request_stop)
    workers = {}
    for region in range(int(config['session_count'])):
        proc = mp.Process(target=scan_region, args=(config, region), name=f'coverage-region-{region:02d}')
        proc.start(); workers[region] = proc; time.sleep(0.04)
    supervisor = pathlib.Path(config['state_dir']) / 'supervisor.json'
    atomic_json(supervisor, snapshot(config, workers, 'running'))
    try:
        while not STOP and not stop_file.exists():
            atomic_json(supervisor, snapshot(config, workers, 'running'))
            if not any(proc.is_alive() for proc in workers.values()):
                break
            time.sleep(0.4)
    finally:
        atomic_json(supervisor, snapshot(config, workers, 'stopping'))
        for proc in workers.values():
            if proc.is_alive(): proc.terminate()
        deadline=time.time()+8
        for proc in workers.values(): proc.join(max(0.1, deadline-time.time()))
        for proc in workers.values():
            if proc.is_alive(): proc.kill(); proc.join(1)
        atomic_json(supervisor, snapshot(config, workers, 'stopped'))

if __name__ == '__main__':
    main()
