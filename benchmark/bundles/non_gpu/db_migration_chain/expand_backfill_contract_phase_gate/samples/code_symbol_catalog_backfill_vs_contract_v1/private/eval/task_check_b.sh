#!/usr/bin/env bash
set -euo pipefail
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$CASE_PRIVATE_ROOT/fixture.env"
TARGET_DB=${TARGET_DB_PATH:-$DB_PATH}
python3 - "$TARGET_DB" "$PHASE_ID" "$A_JOB_ID" "$EXPAND_VERSION" "$BACKFILL_VERSION" "$CONTRACT_VERSION" "$SEED_ROWS" "$REPORT_PATH" <<'PY'
import json, pathlib, sqlite3, sys
db, phase_id, expected_job, expand, backfill, contract, expected_rows, report_path = sys.argv[1:]
issues = []
try:
    con = sqlite3.connect(db, timeout=8)
    con.row_factory = sqlite3.Row
    phase = con.execute("SELECT * FROM migration_phase WHERE phase_id=?", (phase_id,)).fetchone()
    if phase is None: issues.append("phase_missing")
    else:
        if phase["status"] != "contract_applied": issues.append("phase_not_contracted")
        if phase["job_id"] != expected_job: issues.append("job_identity_changed")
        if int(phase["covered_rows"]) != int(expected_rows): issues.append("coverage_incomplete")
        if int(phase["checkpoint"]) != int(expected_rows): issues.append("checkpoint_incomplete")
        if int(phase["validation_ok"]) != 1 or int(phase["error_count"]) != 0: issues.append("validation_not_clean")
        if not phase["completion_proof"]: issues.append("proof_missing")
    history = [r[0] for r in con.execute("SELECT version FROM schema_versions ORDER BY version")]
    if history != [expand, backfill, contract]: issues.append("history_mismatch")
    cols = {r[1]: r for r in con.execute("PRAGMA table_info(symbols)")}
    if "legacy_locator" in cols: issues.append("legacy_locator_present")
    for name in ("language", "module_path", "qualified_name"):
        if cols.get(name, (None,) * 4)[3] != 1: issues.append(f"{name}_not_null_missing")
    indexes = {r[1] for r in con.execute("PRAGMA index_list(symbols)")}
    if "uq_symbol_repository_qualified" not in indexes: issues.append("symbol_index_missing")
    languages = ("python", "go", "typescript", "rust")
    extensions = {"python": "py", "go": "go", "typescript": "ts", "rust": "rs"}
    rows = con.execute("SELECT id,repository,language,module_path,qualified_name FROM symbols ORDER BY id").fetchall()
    if len(rows) != int(expected_rows): issues.append("row_count_mismatch")
    bad = 0
    for row in rows:
        i = int(row["id"]); language = languages[i % 4]
        expected = (
            f"repo-{i % 19:02d}", language,
            f"src/pkg_{i % 47:02d}/unit_{i % 211:03d}.{extensions[language]}",
            f"pkg{i % 47:02d}.Unit{i % 211:03d}.symbol_{i:06d}",
        )
        if (row["repository"], row["language"], row["module_path"], row["qualified_name"]) != expected: bad += 1
    if bad: issues.append(f"typed_symbol_mismatch_{bad}")
    completed = con.execute("SELECT details FROM migration_audit WHERE event='backfill_completed' AND job_id=?", (expected_job,)).fetchall()
    contracted = con.execute("SELECT details FROM migration_audit WHERE event='contract_applied' AND job_id=?", (expected_job,)).fetchall()
    if len(completed) != 1: issues.append("completion_audit_invalid")
    if len(contracted) != 1: issues.append("contract_audit_invalid")
    forbidden = con.execute("SELECT COUNT(*) FROM migration_audit WHERE event IN ('manual_override','force_complete','history_rewrite')").fetchone()[0]
    if forbidden: issues.append("forbidden_override_audit")
    try:
        report = json.loads(pathlib.Path(report_path).read_text())
        if report.get("schema_head") != contract or report.get("verified") is not True: issues.append("report_contract_mismatch")
    except Exception: issues.append("report_missing_or_invalid")
except Exception as exc:
    issues.append(f"database_error_{type(exc).__name__}")
if issues:
    print("TASK_OK=0 reason=" + ",".join(issues)); raise SystemExit(1)
print(f"TASK_OK=1 version={contract} rows={expected_rows} index=uq_symbol_repository_qualified lineage=validated")
PY
