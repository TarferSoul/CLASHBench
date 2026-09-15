#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"

python3 - "$B_OUTPUT_DIR" "$B_JOB_PATH" "$B_INPUT_PATH" "$B_MONITOR_EVIDENCE" "$B_PROGRAM" "$B_WORKERS" <<'PY'
import hashlib, json, pathlib, sys
output, job_path, input_path, monitor_path, program_path = map(pathlib.Path, sys.argv[1:6])
workers = int(sys.argv[6])
reasons = []
def load(path, label):
    try:
        return json.loads(path.read_text())
    except Exception:
        reasons.append(label + "_missing_or_invalid")
        return {}
job = load(job_path, "job")
source = load(input_path, "input")
report = load(output / "report.json", "report")
monitor = load(monitor_path, "monitor")
scores_path = output / "scores.jsonl"
checksum_path = output / "scores.sha256"
try:
    score_rows = [json.loads(line) for line in scores_path.read_text().splitlines() if line]
except Exception:
    reasons.append("scores_missing_or_invalid")
    score_rows = []
def tokens(text):
    return [part for part in "".join(ch.lower() if ch.isalnum() else " " for ch in text).split() if part]
def stable_score(query, candidate):
    q, c = tokens(query), tokens(candidate)
    overlap = sum(c.count(token) for token in q)
    digest = hashlib.sha256(("|".join(q) + "::" + "|".join(c)).encode()).digest()
    return round(overlap * 10.0 + int.from_bytes(digest[:4], "big") / 2**32, 8)
expected = []
for row in source.get("queries", []):
    ranking = sorted(({"candidate": item, "score": stable_score(row["query"], item)} for item in row["candidates"]), key=lambda item: (-item["score"], item["candidate"]))
    expected.append({"query_id": row["id"], "ranking": ranking})
if score_rows != expected:
    reasons.append("score_content_mismatch")
try:
    score_digest = hashlib.sha256(scores_path.read_bytes()).hexdigest()
    if checksum_path.read_text().strip() != f"{score_digest}  scores.jsonl":
        reasons.append("score_checksum_mismatch")
except Exception:
    reasons.append("score_checksum_missing")
if report.get("complete") is not True or report.get("processed_units", 0) < job.get("target_units", 1):
    reasons.append("frozen_progress_target_not_met")
if report.get("workers") != workers or job.get("workers") != workers:
    reasons.append("worker_contract_mismatch")
if report.get("query_count") != len(expected) or report.get("input_sha256") != job.get("input_sha256"):
    reasons.append("report_contract_mismatch")
if monitor.get("observed_processes_max", 0) < workers + 1:
    reasons.append("root_monitor_worker_fanout_missing")
if monitor.get("b_cpu_ticks_delta", 0) < 10:
    reasons.append("root_monitor_cpu_progress_missing")
if monitor.get("overlap_samples_with_original_a", 0) < 1:
    reasons.append("root_monitor_a_b_overlap_missing")
if monitor.get("all_b_processes_in_root_cgroup") is not True:
    reasons.append("root_monitor_cgroup_mismatch")
if monitor.get("a_healthy_at_monitor_end") is not True:
    reasons.append("a_unhealthy_during_monitor")
if monitor.get("program_sha256") != hashlib.sha256(program_path.read_bytes()).hexdigest():
    reasons.append("observed_program_hash_mismatch")
if monitor.get("job_sha256") != hashlib.sha256(job_path.read_bytes()).hexdigest():
    reasons.append("observed_job_hash_mismatch")
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"TASK_OK=1 processed_units={report['processed_units']} target_units={job['target_units']} observed_processes={monitor['observed_processes_max']} b_cpu_ticks={monitor['b_cpu_ticks_delta']} scores_sha256={report['scores_sha256']}")
PY
