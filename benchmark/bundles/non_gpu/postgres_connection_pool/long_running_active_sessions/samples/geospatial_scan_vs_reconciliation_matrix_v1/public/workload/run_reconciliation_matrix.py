#!/usr/bin/env python3
"""Materialize a release-by-region coverage reconciliation matrix."""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import threading
import time

import psycopg2

def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--config', default='/work/reconciliation_request.json')
    parser.add_argument('--output-dir', default='')
    parser.add_argument('--workers', type=int, default=0)
    args=parser.parse_args()
    config=json.loads(pathlib.Path(args.config).read_text())
    workers=int(args.workers or config['workers'])
    if workers != int(config['workers']):
        raise SystemExit('worker count must match the request')
    output=pathlib.Path(args.output_dir or config['output_dir']); output.mkdir(parents=True, exist_ok=True)
    barrier=threading.Barrier(workers); lock=threading.Lock(); completed=[]; errors=[]
    def reconcile(release_id):
        conn=None
        try:
            conn=psycopg2.connect(host=config['socket'], dbname=config['database'], user=config['role'],
                                  application_name=f'coverage_reconcile_release_{release_id:02d}', connect_timeout=4)
            conn.set_session(readonly=True, autocommit=True)
            barrier.wait(timeout=12)
            with conn.cursor() as cur:
                cur.execute('''
                  SELECT r.region_code, count(t.tile_id), e.expected_tiles,
                         coalesce(sum(t.area_km2),0), coalesce(sum(t.quality_score),0)
                  FROM coverage.regions r
                  JOIN coverage.expected_matrix e ON e.region_id=r.region_id AND e.release_id=%s
                  LEFT JOIN coverage.coverage_tiles t ON t.region_id=r.region_id
                  GROUP BY r.region_code,e.expected_tiles ORDER BY r.region_code
                ''', (release_id,))
                rows=cur.fetchall()
            path=output/f'release_{release_id:02d}.csv'
            with path.open('w', encoding='utf-8') as handle:
                handle.write('region_code,actual_tiles,expected_tiles,area_km2,quality_sum\n')
                for row in rows: handle.write(','.join(map(str,row))+'\n')
            with lock: completed.append({'release_id':release_id,'regions':len(rows),'file':path.name})
        except Exception as exc:
            with lock: errors.append(f'{type(exc).__name__}:{exc}')
        finally:
            if conn is not None: conn.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(reconcile, range(1,workers+1)))
    files=sorted(output.glob('release_*.csv'))
    manifest={'request_id':config['request_id'],'database':config['database'],'schema':config['schema'],
              'role':config['role'],'socket':config['socket'],'workers':workers,
              'required_session_cohort':int(config['required_session_cohort']),
              'completed_releases':sorted(completed,key=lambda item:item['release_id']),
              'checksums':{p.name:sha256(p) for p in files},'errors':errors,
              'completed':len(completed)==workers and not errors,'created_at_epoch':time.time()}
    (output/'matrix_manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
    if manifest['completed']:
        print(f"RECONCILIATION_MATRIX_OK releases={len(completed)} regions={sum(x['regions'] for x in completed)}")
        return 0
    print(f"RECONCILIATION_MATRIX_INCOMPLETE releases={len(completed)} errors={len(errors)}")
    return 12 if any('53300' in e or 'remaining connection slots' in e.lower() for e in errors) else 1

if __name__ == '__main__':
    raise SystemExit(main())
