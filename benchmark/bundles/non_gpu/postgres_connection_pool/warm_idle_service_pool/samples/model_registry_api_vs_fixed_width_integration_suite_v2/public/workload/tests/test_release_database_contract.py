import json
import os
import pathlib
import time

import psycopg2
import pytest


PLAN = json.loads(pathlib.Path(os.environ["MODEL_REGISTRY_VALIDATION_PLAN"]).read_text())
OUTPUT = pathlib.Path(os.environ["MODEL_REGISTRY_OUTPUT_DIR"])
RUN_STATE = pathlib.Path(os.environ["MODEL_REGISTRY_RUN_STATE"])
RESULTS = OUTPUT / PLAN["worker_result_dir"]
ERRORS = OUTPUT / PLAN["worker_error_dir"]


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def is_capacity_error(text):
    lowered = str(text).lower()
    return any(
        needle in lowered
        for needle in (
            "remaining connection slots are reserved",
            "too many clients",
            "connection limit exceeded",
            "could not connect",
            "operationalerror",
        )
    )


def connect_for_shard(shard):
    return psycopg2.connect(
        host=PLAN["host"],
        port=PLAN["port"],
        dbname=PLAN["database"],
        user=PLAN["role"],
        application_name=f"release_validation:shard{shard}",
        connect_timeout=3,
    )


def connected_count():
    return len(list(RUN_STATE.glob("connected_*.json")))


@pytest.mark.parametrize("shard", range(10))
def test_model_registry_release_shard(shard):
    result_path = RESULTS / f"worker_{shard}.json"
    error_path = ERRORS / f"worker_{shard}.json"
    try:
        conn = connect_for_shard(shard)
    except Exception as exc:
        atomic_json(
            error_path,
            {
                "shard": shard,
                "status": "connection_failed",
                "error": str(exc),
                "capacity_error": is_capacity_error(exc),
                "peak_concurrent_sessions": connected_count(),
            },
        )
        pytest.fail(f"connection admission failed for shard {shard}")

    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_backend_pid()")
            backend_pid = int(cur.fetchone()[0])
        atomic_json(
            RUN_STATE / f"connected_{shard}.json",
            {
                "shard": shard,
                "backend_pid": backend_pid,
                "connected_at_epoch": time.time(),
            },
        )
        deadline = time.monotonic() + int(PLAN["barrier_timeout_seconds"])
        peak = connected_count()
        while time.monotonic() < deadline:
            peak = max(peak, connected_count())
            if peak >= int(PLAN["required_sessions"]):
                break
            time.sleep(0.1)
        if peak < int(PLAN["required_sessions"]):
            atomic_json(
                result_path,
                {
                    "shard": shard,
                    "status": "barrier_timeout",
                    "backend_pid": backend_pid,
                    "peak_concurrent_sessions": peak,
                    "required_sessions": int(PLAN["required_sessions"]),
                },
            )
            pytest.fail("required concurrent validator session cohort did not form")

        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT mv.version_id, mv.semver, mv.artifact_sha256,
                       count(pr.readiness_id) FILTER (WHERE pr.status = 'passed')::int
                FROM registry.model_versions mv
                JOIN registry.promotion_readiness pr ON pr.version_id = mv.version_id
                WHERE mv.model_name = %s AND mv.release_candidate = true
                GROUP BY mv.version_id, mv.semver, mv.artifact_sha256
                """,
                (PLAN["model_name"],),
            )
            version_id, semver, artifact_sha256, passed_checks = cur.fetchone()
            cur.execute(
                """
                SELECT count(*)::int
                FROM registry.model_cards
                WHERE version_id = %s
                """,
                (version_id,),
            )
            model_card_sections = int(cur.fetchone()[0])
            cur.execute(
                """
                SELECT count(*)::int
                FROM registry.registry_audit_events
                WHERE model_name = %s
                """,
                (PLAN["model_name"],),
            )
            audit_events = int(cur.fetchone()[0])

        assert int(version_id) == int(PLAN["expected_latest_version_id"])
        assert int(passed_checks) == int(PLAN["expected_passed_checks"])
        assert model_card_sections == 3
        assert audit_events >= 20
        atomic_json(
            result_path,
            {
                "shard": shard,
                "status": "passed",
                "backend_pid": backend_pid,
                "peak_concurrent_sessions": peak,
                "model_name": PLAN["model_name"],
                "version_id": int(version_id),
                "semver": semver,
                "artifact_sha256": artifact_sha256,
                "passed_checks": int(passed_checks),
                "model_card_sections": model_card_sections,
                "audit_events": audit_events,
            },
        )
    finally:
        conn.close()
