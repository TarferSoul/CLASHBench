#!/usr/bin/python3
import json
import os
import pathlib
import sys

import psycopg2

result_path = pathlib.Path(sys.argv[1])
pid_path = pathlib.Path(sys.argv[2])
timeout_ms = int(sys.argv[3])
payload = {
    "partition_key": os.environ["TARGET_PARTITION"],
    "audit_id": os.environ["TARGET_AUDIT_ID"],
}
conn = psycopg2.connect(
    host=os.environ["PG_SOCKET"], port=int(os.environ["PG_PORT"]),
    dbname=os.environ["LIVE_DB"], user=os.environ["B_DB_USER"],
    application_name=os.environ["B_APPLICATION_NAME"],
)
conn.autocommit = False
try:
    with conn.cursor() as cur:
        cur.execute("SET lock_timeout = %s", (timeout_ms,))
        pid_path.write_text(str(conn.get_backend_pid()) + "\n")
        cur.execute(
            "INSERT INTO feature_partitions "
            "(snapshot_id, partition_key, object_uri, row_count, content_digest, validation_status) "
            "VALUES (%s,%s,%s,%s,%s,'registered') "
            "RETURNING partition_id, row_version",
            (os.environ["SNAPSHOT_ID"], os.environ["TARGET_PARTITION"], os.environ["TARGET_URI"],
             int(os.environ["TARGET_ROWS"]), os.environ["TARGET_DIGEST"]),
        )
        partition_id, row_version = cur.fetchone()
        cur.execute(
            "INSERT INTO feature_partition_audit (audit_id, partition_key, operation, committed_row_version) "
            "VALUES (%s,%s,'late_partition_registration',%s)",
            (os.environ["TARGET_AUDIT_ID"], os.environ["TARGET_PARTITION"], row_version),
        )
    conn.commit()
    payload.update(status="committed", partition_id=partition_id, row_version=row_version)
    result_path.write_text(json.dumps(payload, sort_keys=True) + "\n")
except psycopg2.Error as exc:
    conn.rollback()
    payload.update(status="database_error", sqlstate=exc.pgcode, message=str(exc).splitlines()[0])
    result_path.write_text(json.dumps(payload, sort_keys=True) + "\n")
    sys.exit(10)
finally:
    conn.close()
