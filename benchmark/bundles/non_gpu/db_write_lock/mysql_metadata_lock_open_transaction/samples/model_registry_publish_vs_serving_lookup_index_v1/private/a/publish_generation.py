#!/usr/bin/python3
import hashlib
import json
import os
import pathlib
import signal
import sys
import time

import pymysql

state_path = pathlib.Path(os.environ["WORKER_STATE"])
publication_id = os.environ["PUBLICATION_ID"]
routing_generation = os.environ["ROUTING_GENERATION"]
expected_count = int(os.environ["TARGET_ROW_COUNT"])
verification_passes = int(os.environ["VERIFICATION_PASSES"])
minimum_seconds = float(os.environ["MIN_VERIFICATION_SECONDS"])
stopping = False


def write_state(**values):
    payload = {"publication_id": publication_id, "routing_generation": routing_generation,
               "pid": os.getpid(), "updated_at": time.time(), **values}
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n")
    temporary.replace(state_path)


def request_stop(_signum, _frame):
    global stopping
    stopping = True


def expected_artifact_digest(row):
    row_id, tenant_key, model_key, version_tag, artifact_uri = row[:5]
    canonical = "|".join((publication_id, tenant_key, model_key, version_tag, artifact_uri))
    return hashlib.sha256(canonical.encode("ascii")).hexdigest(), int(row_id)


def pace(started, completed, total):
    target = minimum_seconds * completed / max(total, 1)
    remaining = target - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(min(remaining, 0.3))


signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)
conn = pymysql.connect(
    unix_socket=os.environ["MYSQL_SOCKET"], user=os.environ["WORKER_DB_USER"],
    password="", database=os.environ["LIVE_DB"], autocommit=False, charset="utf8mb4"
)
try:
    with conn.cursor() as cursor:
        cursor.execute("SELECT CONNECTION_ID()")
        connection_id = int(cursor.fetchone()[0])
        conn.begin()
        cursor.execute(
            "UPDATE model_versions SET serving_status='verifying' "
            "WHERE publication_id=%s AND serving_status='staged'", (publication_id,)
        )
        if cursor.rowcount != expected_count:
            raise RuntimeError(f"expected {expected_count} staged versions, updated {cursor.rowcount}")
        cursor.execute(
            "SELECT id,tenant_key,model_key,version_tag,artifact_uri,artifact_sha256,"
            "routing_weight,routing_generation FROM model_versions "
            "WHERE publication_id=%s ORDER BY tenant_key,model_key,id", (publication_id,)
        )
        rows = cursor.fetchall()
        if len(rows) != expected_count:
            raise RuntimeError(f"expected {expected_count} model versions, found {len(rows)}")
        checks = ("artifact-digest", "routing-weight", "tenant-coverage", "generation-consistency", "activation-order")
        total = expected_count * verification_passes
        started = time.monotonic()
        verified = 0
        receipt = hashlib.sha256()
        write_state(phase="verifying", connection_id=connection_id, verified_count=0,
                    verification_total=total, current_check="claim", last_event_sequence=0)
        for pass_index in range(verification_passes):
            check_name = checks[pass_index]
            seen_tenants = set()
            previous_key = None
            for offset, row in enumerate(rows, start=1):
                if stopping:
                    conn.rollback()
                    write_state(phase="rolled_back", connection_id=connection_id,
                                verified_count=verified, verification_total=total,
                                current_check=check_name, last_event_sequence=max(0, offset - 1))
                    sys.exit(0)
                expected, row_id = expected_artifact_digest(row)
                if check_name == "artifact-digest" and row[5] != expected:
                    raise RuntimeError(f"artifact digest mismatch for row {row_id}")
                if check_name == "routing-weight" and not 1 <= int(row[6]) <= 100:
                    raise RuntimeError(f"invalid routing weight for row {row_id}")
                if check_name == "tenant-coverage":
                    seen_tenants.add(row[1])
                if check_name == "generation-consistency" and row[7] != routing_generation:
                    raise RuntimeError(f"routing generation mismatch for row {row_id}")
                if check_name == "activation-order":
                    key = (row[1], row[2], int(row[0]))
                    if previous_key is not None and key < previous_key:
                        raise RuntimeError(f"activation order regression at row {row_id}")
                    previous_key = key
                    receipt.update(f"{row_id}:{expected}:{row[6]}".encode("ascii"))
                verified += 1
                if verified % 80 == 0:
                    sequence = verified // 80
                    cursor.execute(
                        "INSERT INTO publication_verification_events "
                        "(publication_id,check_name,sequence_no,rows_seen,evidence_digest,created_at) "
                        "VALUES (%s,%s,%s,%s,%s,NOW(6))",
                        (publication_id, check_name, sequence, verified,
                         receipt.hexdigest() if check_name == "activation-order" else expected),
                    )
                    write_state(phase="verifying", connection_id=connection_id,
                                verified_count=verified, verification_total=total,
                                current_check=check_name, last_event_sequence=sequence,
                                tenants_observed=len(seen_tenants))
                    pace(started, verified, total)
            if check_name == "tenant-coverage" and len(seen_tenants) != 80:
                raise RuntimeError(f"expected 80 tenants, found {len(seen_tenants)}")
        cursor.execute(
            "UPDATE model_versions SET serving_status='active',activated_at=NOW(6),verified_at=NOW(6) "
            "WHERE publication_id=%s AND serving_status='verifying'", (publication_id,)
        )
        if cursor.rowcount != expected_count:
            raise RuntimeError(f"expected to activate {expected_count} versions, updated {cursor.rowcount}")
        conn.commit()
        write_state(phase="committed", connection_id=connection_id,
                    verified_count=verified, verification_total=verified,
                    current_check="complete", last_event_sequence=verified // 80,
                    publication_receipt=receipt.hexdigest(),
                    elapsed_seconds=round(time.monotonic() - started, 3))
except Exception as exc:
    conn.rollback()
    write_state(phase="failed", error=str(exc), connection_id=locals().get("connection_id"),
                verified_count=locals().get("verified", 0))
    raise
finally:
    conn.close()
