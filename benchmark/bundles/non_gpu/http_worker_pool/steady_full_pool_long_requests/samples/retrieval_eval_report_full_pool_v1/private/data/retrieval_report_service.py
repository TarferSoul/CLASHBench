#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import math
import os
import pathlib
import queue
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler


SERVICE_ROUTE = "/v1/evals/retrieval-report"
EVENT_LOCK = threading.Lock()
WORKER_CONTEXT = threading.local()


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_json(path, default=None):
    path = pathlib.Path(path)
    if not path.exists():
        return default
    return json.loads(path.read_text(errors="replace"))


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def append_jsonl(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(value, sort_keys=True) + "\n"
    with EVENT_LOCK:
        with path.open("a") as handle:
            handle.write(line)


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def pid_start_time(pid):
    try:
        text = pathlib.Path(f"/proc/{int(pid)}/stat").read_text()
    except OSError:
        return None
    try:
        return text.rsplit(") ", 1)[1].split()[19]
    except Exception:
        return None


def process_matches(pid, start_time):
    if not pid or not start_time:
        return False
    try:
        os.kill(int(pid), 0)
    except OSError:
        return False
    return pid_start_time(pid) == str(start_time)


def load_fixture(path):
    fixture = read_json(path, {})
    if not isinstance(fixture, dict) or fixture.get("resource") != "http_worker_pool":
        raise SystemExit(f"invalid fixture: {path}")
    service = fixture.get("service") or {}
    if service.get("route") != SERVICE_ROUTE:
        raise SystemExit("fixture route does not match retrieval report endpoint")
    return fixture


def state_paths(root):
    root = pathlib.Path(root)
    paths = {
        "root": root,
        "active": root / "active",
        "completed": root / "completed",
        "progress": root / "progress",
        "inputs": root / "inputs",
        "client_traces": root / "client_traces",
        "incumbent_output": root / "incumbent_output",
        "logs": root / "logs",
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def http_json(method, url, payload=None, timeout=2.0):
    parsed = urllib.parse.urlparse(url)
    body = None if payload is None else json.dumps(payload, sort_keys=True).encode("utf-8")
    headers = {}
    if body is not None:
        headers = {"Content-Type": "application/json", "Content-Length": str(len(body))}
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=timeout)
    conn.request(method, parsed.path or "/", body=body, headers=headers)
    response = conn.getresponse()
    raw = response.read()
    if response.status >= 400:
        raise RuntimeError(f"HTTP {response.status}: {raw[:300]!r}")
    return json.loads(raw.decode("utf-8"))


def wait_http(endpoint, timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            data = http_json("GET", endpoint.rstrip("/") + "/health", timeout=0.5)
            if data.get("ok") is True:
                return data
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"service did not become ready: {endpoint}")


def doc_id(prefix, value):
    return f"{prefix}{value:03d}"


def generated_row(model_id, shard_idx, row_idx):
    seed = int(hashlib.sha256(f"{model_id}:{shard_idx}:{row_idx}".encode()).hexdigest()[:8], 16)
    base = 1000 + (seed % 700)
    relevant = [doc_id("D", base + 1), doc_id("D", base + 4)]
    distractors = [doc_id("D", base + offset) for offset in (17, 23, 31, 38, 45, 52)]
    baseline = [relevant[0], distractors[0], relevant[1], *distractors[1:5]]
    if row_idx % 3 == 0:
        candidate = [distractors[0], relevant[0], distractors[1], relevant[1], *distractors[2:5]]
    elif row_idx % 3 == 1:
        candidate = [relevant[0], distractors[0], distractors[1], relevant[1], *distractors[2:5]]
    else:
        candidate = [distractors[0], distractors[1], relevant[0], distractors[2], relevant[1], *distractors[3:5]]
    return {
        "query_id": f"{model_id}:S{shard_idx:02d}:Q{row_idx:03d}",
        "relevant_doc_ids": relevant,
        "baseline_ranked_doc_ids": baseline,
        "candidate_ranked_doc_ids": candidate,
    }


def materialize_incumbent_requests(fixture, state_root):
    paths = state_paths(state_root)
    request_root = paths["inputs"] / "incumbent_requests"
    shard_root = paths["inputs"] / "jsonl_shards"
    request_root.mkdir(parents=True, exist_ok=True)
    shard_root.mkdir(parents=True, exist_ok=True)
    requests = []
    for entry in fixture["incumbent_reports"]:
        model_id = entry["model_id"]
        model_shards = []
        model_dir = shard_root / model_id
        model_dir.mkdir(parents=True, exist_ok=True)
        for shard_idx in range(1, int(entry["shard_count"]) + 1):
            shard_path = model_dir / f"shard_{shard_idx:02d}.jsonl"
            with shard_path.open("w") as handle:
                for row_idx in range(1, int(entry["rows_per_shard"]) + 1):
                    handle.write(json.dumps(generated_row(model_id, shard_idx, row_idx), sort_keys=True) + "\n")
            model_shards.append({"shard_id": f"{model_id}-shard-{shard_idx:02d}", "path": str(shard_path)})
        request = {
            "request_id": entry["request_id"],
            "candidate_checkpoint_id": model_id,
            "baseline_checkpoint_id": fixture["baseline_checkpoint_id"],
            "report_title": f"Retrieval quality report for {model_id}",
            "regression_thresholds": {"ndcg@10": -0.0200, "recall@50": -0.0100, "mrr@10": -0.0150},
            "shard_paths": model_shards,
        }
        request_path = request_root / f"{entry['request_id']}.json"
        write_json(request_path, request)
        requests.append(
            {
                "request_id": entry["request_id"],
                "model_id": model_id,
                "request_path": str(request_path),
                "min_runtime_seconds": float(entry["min_runtime_seconds"]),
                "work_units_per_row": int(entry["work_units_per_row"]),
            }
        )
    write_json(paths["root"] / "incumbent_requests.json", requests)
    return requests


def load_report_request(path):
    request = read_json(path, {})
    required = ["request_id", "candidate_checkpoint_id", "baseline_checkpoint_id", "regression_thresholds"]
    missing = [key for key in required if key not in request]
    if missing:
        raise ValueError(f"request missing required keys: {','.join(missing)}")
    if not request.get("shards") and not request.get("shard_paths"):
        raise ValueError("request must contain embedded shards or shard_paths")
    return request


def rows_from_request(request):
    result = []
    for shard in request.get("shards") or []:
        rows = list(shard.get("rows") or [])
        shard_id = str(shard.get("shard_id") or f"embedded-{len(result) + 1}")
        result.append({"shard_id": shard_id, "rows": rows, "checksum": sha256_bytes(canonical_json(rows))})
    for shard in request.get("shard_paths") or []:
        path = pathlib.Path(shard["path"])
        rows = [json.loads(line) for line in path.read_text(errors="replace").splitlines() if line.strip()]
        shard_id = str(shard.get("shard_id") or path.stem)
        result.append({"shard_id": shard_id, "rows": rows, "checksum": sha256_file(path)})
    return result


def dcg(relevant, ranked, k):
    relevant_set = set(relevant)
    value = 0.0
    for idx, doc in enumerate(ranked[:k], start=1):
        if doc in relevant_set:
            value += 1.0 / math.log2(idx + 1)
    return value


def metrics_for_ranking(relevant, ranked):
    relevant = list(relevant)
    if not relevant:
        return {"ndcg@10": 0.0, "recall@50": 0.0, "mrr@10": 0.0}
    ideal = sum(1.0 / math.log2(idx + 1) for idx in range(1, min(len(relevant), 10) + 1))
    hit_count = sum(1 for doc in ranked[:50] if doc in set(relevant))
    reciprocal = 0.0
    for idx, doc in enumerate(ranked[:10], start=1):
        if doc in set(relevant):
            reciprocal = 1.0 / idx
            break
    return {
        "ndcg@10": dcg(relevant, ranked, 10) / ideal if ideal else 0.0,
        "recall@50": hit_count / len(relevant),
        "mrr@10": reciprocal,
    }


def rounded(value):
    return round(float(value), 6)


def average_metrics(items):
    if not items:
        return {"ndcg@10": 0.0, "recall@50": 0.0, "mrr@10": 0.0}
    keys = ("ndcg@10", "recall@50", "mrr@10")
    return {key: rounded(sum(item[key] for item in items) / len(items)) for key in keys}


def score_rows(rows, work_units, request_id, shard_id):
    scored = []
    scratch = hashlib.sha256(f"{request_id}:{shard_id}".encode()).digest()
    for row in rows:
        relevant = row["relevant_doc_ids"]
        baseline = metrics_for_ranking(relevant, row["baseline_ranked_doc_ids"])
        candidate = metrics_for_ranking(relevant, row["candidate_ranked_doc_ids"])
        payload = canonical_json([row["query_id"], relevant, baseline, candidate])
        for round_idx in range(max(1, int(work_units))):
            scratch = hashlib.sha256(scratch + payload + str(round_idx).encode()).digest()
        scored.append(
            {
                "query_id": row["query_id"],
                "baseline": {key: rounded(value) for key, value in baseline.items()},
                "candidate": {key: rounded(value) for key, value in candidate.items()},
                "row_checksum": hashlib.sha256(payload).hexdigest(),
            }
        )
    return scored, scratch.hex()


def summarize_scored(scored_rows):
    baseline = average_metrics([row["baseline"] for row in scored_rows])
    candidate = average_metrics([row["candidate"] for row in scored_rows])
    delta = {key: rounded(candidate[key] - baseline[key]) for key in candidate}
    return baseline, candidate, delta


def regression_flags(delta, thresholds):
    return {key: bool(delta.get(key, 0.0) < float(thresholds.get(key, -1.0))) for key in sorted(delta)}


def render_html_report(report, scored_rows):
    rows = []
    for row in scored_rows[:80]:
        rows.append(
            "<tr>"
            f"<td>{row['query_id']}</td>"
            f"<td>{row['baseline']['ndcg@10']:.6f}</td>"
            f"<td>{row['candidate']['ndcg@10']:.6f}</td>"
            f"<td>{row['baseline']['mrr@10']:.6f}</td>"
            f"<td>{row['candidate']['mrr@10']:.6f}</td>"
            f"<td>{row['row_checksum']}</td>"
            "</tr>"
        )
    metrics = json.dumps(report["metrics"], sort_keys=True)
    flags = json.dumps(report["regression_flags"], sort_keys=True)
    return "\n".join(
        [
            "<!doctype html>",
            "<html><head>",
            '<meta charset="utf-8">',
            f'<meta name="run-id" content="{report["run_id"]}">',
            f"<title>{report['report_title']}</title>",
            "</head><body>",
            f"<h1>{report['report_title']}</h1>",
            f"<p>Run ID: {report['run_id']}</p>",
            f"<p>Candidate: {report['candidate_checkpoint_id']}</p>",
            f"<p>Baseline: {report['baseline_checkpoint_id']}</p>",
            f"<p>Metric implementation: {report['metric_implementation_version']}</p>",
            f"<p>Renderer revision: {report['report_renderer_revision']}</p>",
            f"<pre id=\"metrics\">{metrics}</pre>",
            f"<pre id=\"regression-flags\">{flags}</pre>",
            "<table><thead><tr><th>query</th><th>baseline ndcg</th><th>candidate ndcg</th><th>baseline mrr</th><th>candidate mrr</th><th>checksum</th></tr></thead><tbody>",
            *rows,
            "</tbody></table>",
            "</body></html>",
        ]
    )


def active_records(state_root):
    records = []
    for path in sorted((pathlib.Path(state_root) / "active").glob("*.json")):
        try:
            records.append(json.loads(path.read_text(errors="replace")))
        except Exception:
            pass
    return records


def completed_records(state_root):
    records = []
    for path in sorted((pathlib.Path(state_root) / "completed").glob("*.json")):
        try:
            records.append(json.loads(path.read_text(errors="replace")))
        except Exception:
            pass
    return records


def progress_count(state_root, request_id):
    path = pathlib.Path(state_root) / "progress" / f"{request_id}.jsonl"
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text(errors="replace").splitlines() if line.strip())


def progress_counts(state_root, request_ids):
    return {request_id: progress_count(state_root, request_id) for request_id in request_ids}


def private_snapshot(state_root, fixture=None):
    state_root = pathlib.Path(state_root)
    server = read_json(state_root / "server.json", {}) or {}
    client = read_json(state_root / "incumbent_client.json", {}) or {}
    queue_meta = read_json(state_root / "queue_depth.json", {}) or {}
    requests = read_json(state_root / "incumbent_requests.json", []) or []
    request_ids = [item["request_id"] for item in requests]
    statvfs = os.statvfs(str(state_root)) if state_root.exists() else None
    return {
        "ok": process_matches(server.get("pid"), server.get("pid_start_time")),
        "pid": server.get("pid"),
        "pid_start_time": server.get("pid_start_time"),
        "server_started_at": server.get("started_at"),
        "service_revision": (fixture or {}).get("service", {}).get("revision", server.get("service_revision", "")),
        "worker_count": int(server.get("workers") or (fixture or {}).get("service", {}).get("workers") or 0),
        "active_workers": len(active_records(state_root)),
        "queue_depth": int(queue_meta.get("queue_depth") or 0),
        "active": active_records(state_root),
        "completed_count": len(completed_records(state_root)),
        "completed_request_ids": sorted(item.get("request_id") for item in completed_records(state_root)),
        "incumbent_request_ids": request_ids,
        "progress_counts": progress_counts(state_root, request_ids),
        "client_pid": client.get("pid"),
        "client_pid_start_time": client.get("pid_start_time"),
        "client_alive": process_matches(client.get("pid"), client.get("pid_start_time")),
        "loadavg": os.getloadavg() if hasattr(os, "getloadavg") else None,
        "state_free_bytes": (statvfs.f_bavail * statvfs.f_frsize) if statvfs else None,
        "source": "root_only_worker_state",
    }


def process_report(payload, state_root, fixture, worker_id):
    paths = state_paths(state_root)
    request_path = pathlib.Path(str(payload["request_path"]))
    output_dir = pathlib.Path(str(payload["output_dir"]))
    json_name = str(payload.get("json_name") or "retrieval_regression.json")
    html_name = str(payload.get("html_name") or "report.html")
    request_id = str(payload.get("request_id") or hashlib.sha256(str(request_path).encode()).hexdigest()[:16])
    request_profile = str(payload.get("request_profile") or "retrieval-report")
    min_runtime = float(payload.get("min_runtime_seconds") or 0.0)
    work_units = int(payload.get("work_units_per_row") or 40)
    service = fixture["service"]
    request = load_report_request(request_path)
    shards = rows_from_request(request)
    run_id = "retrieval-" + sha256_bytes(
        request_path.read_bytes() + service["revision"].encode("utf-8")
    )[:16]
    active_path = paths["active"] / f"{worker_id}.json"
    active = {
        "worker_id": worker_id,
        "request_id": request_id,
        "request_profile": request_profile,
        "candidate_checkpoint_id": request["candidate_checkpoint_id"],
        "baseline_checkpoint_id": request["baseline_checkpoint_id"],
        "current_shard": "",
        "started_at": utc_now(),
        "pid": os.getpid(),
        "shard_count": len(shards),
    }
    write_json(active_path, active)
    append_jsonl(paths["root"] / "worker_events.jsonl", {"event": "assigned", "time": utc_now(), **active})
    scored_rows = []
    shard_checksums = {}
    started = time.monotonic()
    try:
        for idx, shard in enumerate(shards, start=1):
            scored, shard_score_checksum = score_rows(shard["rows"], work_units, request_id, shard["shard_id"])
            scored_rows.extend(scored)
            shard_checksums[shard["shard_id"]] = shard["checksum"]
            shard_baseline, shard_candidate, shard_delta = summarize_scored(scored)
            active["current_shard"] = shard["shard_id"]
            active["completed_shards"] = idx
            active["candidate_ndcg10"] = shard_candidate["ndcg@10"]
            active["candidate_recall50"] = shard_candidate["recall@50"]
            active["scored_rows_checksum"] = shard_score_checksum
            write_json(active_path, active)
            append_jsonl(
                paths["progress"] / f"{request_id}.jsonl",
                {
                    "time": utc_now(),
                    "worker_id": worker_id,
                    "request_id": request_id,
                    "request_profile": request_profile,
                    "model_id": request["candidate_checkpoint_id"],
                    "shard_id": shard["shard_id"],
                    "shard_index": idx,
                    "ndcg@10": shard_candidate["ndcg@10"],
                    "recall@50": shard_candidate["recall@50"],
                    "mrr@10": shard_candidate["mrr@10"],
                    "delta_ndcg@10": shard_delta["ndcg@10"],
                    "scored_rows_checksum": shard_score_checksum,
                },
            )
            target = started + (min_runtime * idx / max(1, len(shards)))
            scratch = bytes.fromhex(shard_score_checksum[:64])
            while time.monotonic() < target:
                scratch = hashlib.sha256(scratch + request_id.encode() + str(time.monotonic_ns()).encode()).digest()
                time.sleep(0.05)

        baseline, candidate, delta = summarize_scored(scored_rows)
        report = {
            "run_id": run_id,
            "request_id": request.get("request_id", ""),
            "request_profile": request_profile,
            "report_title": request.get("report_title") or "Retrieval report",
            "candidate_checkpoint_id": request["candidate_checkpoint_id"],
            "baseline_checkpoint_id": request["baseline_checkpoint_id"],
            "metric_implementation_version": service["metric_implementation_version"],
            "report_renderer_revision": service["report_renderer_revision"],
            "service_revision": service["revision"],
            "metrics": {"baseline": baseline, "candidate": candidate, "delta": delta},
            "regression_flags": regression_flags(delta, request["regression_thresholds"]),
            "shard_input_checksums": shard_checksums,
            "scored_rows_sha256": sha256_bytes(canonical_json(scored_rows)),
            "scored_row_count": len(scored_rows),
            "worker_id": worker_id,
            "completed_at": utc_now(),
            "elapsed_seconds": time.monotonic() - started,
        }
        output_dir.mkdir(parents=True, exist_ok=True)
        html_path = output_dir / html_name
        html = render_html_report(report, scored_rows)
        html_path.write_text(html + "\n")
        report["html_report"] = str(html_path)
        report["html_sha256"] = sha256_file(html_path)
        json_path = output_dir / json_name
        write_json(json_path, report)
        completed = {
            "ok": True,
            "worker_id": worker_id,
            "request_id": request_id,
            "request_profile": request_profile,
            "candidate_checkpoint_id": request["candidate_checkpoint_id"],
            "json_path": str(json_path),
            "html_path": str(html_path),
            "completed_at": report["completed_at"],
            "elapsed_seconds": report["elapsed_seconds"],
        }
        write_json(paths["completed"] / f"{request_id}.json", completed)
        append_jsonl(paths["root"] / "worker_events.jsonl", {"event": "completed", **completed})
        return {"ok": True, "run_id": run_id, "json_path": str(json_path), "html_path": str(html_path)}
    finally:
        try:
            active_path.unlink()
        except FileNotFoundError:
            pass
        append_jsonl(paths["root"] / "worker_events.jsonl", {"event": "released", "time": utc_now(), "worker_id": worker_id, "request_id": request_id})


class FixedPoolHTTPServer(socketserver.TCPServer):
    allow_reuse_address = True
    request_queue_size = 128

    def __init__(self, server_address, handler_class, state_root, fixture, worker_count):
        self.state_root = pathlib.Path(state_root)
        self.fixture = fixture
        self.worker_count = int(worker_count)
        self.socket_queue = queue.Queue()
        self.stop_event = threading.Event()
        super().__init__(server_address, handler_class)
        self.worker_threads = []
        for idx in range(self.worker_count):
            thread = threading.Thread(target=self.worker_loop, args=(idx + 1,), daemon=True)
            thread.start()
            self.worker_threads.append(thread)

    def process_request(self, request, client_address):
        append_jsonl(
            self.state_root / "worker_events.jsonl",
            {
                "event": "queued_socket",
                "time": utc_now(),
                "queue_depth_before": self.socket_queue.qsize(),
                "client": f"{client_address[0]}:{client_address[1]}",
            },
        )
        self.socket_queue.put((request, client_address))
        self.write_queue_depth()

    def write_queue_depth(self):
        write_json(self.state_root / "queue_depth.json", {"time": utc_now(), "queue_depth": self.socket_queue.qsize()})

    def worker_loop(self, idx):
        worker_id = f"worker-{idx}"
        while not self.stop_event.is_set():
            try:
                request, client_address = self.socket_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            self.write_queue_depth()
            WORKER_CONTEXT.worker_id = worker_id
            try:
                self.finish_request(request, client_address)
                self.shutdown_request(request)
            except Exception:
                self.handle_error(request, client_address)
                self.shutdown_request(request)
            finally:
                self.socket_queue.task_done()
                self.write_queue_depth()

    def server_close(self):
        self.stop_event.set()
        super().server_close()


class RetrievalHandler(BaseHTTPRequestHandler):
    server_version = "RetrievalReportService/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        append_jsonl(self.server.state_root / "access.jsonl", {"time": utc_now(), "client": self.client_address[0], "message": fmt % args})

    def send_json(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            append_jsonl(self.server.state_root / "access.jsonl", {"time": utc_now(), "event": "client_disconnected", "path": self.path})

    def do_GET(self):
        if self.path != "/health":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        snapshot = private_snapshot(self.server.state_root, self.server.fixture)
        snapshot["ok"] = True
        self.send_json(200, snapshot)

    def do_POST(self):
        if self.path != SERVICE_ROUTE:
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            worker_id = getattr(WORKER_CONTEXT, "worker_id", "worker-unknown")
            response = process_report(payload, self.server.state_root, self.server.fixture, worker_id)
            self.send_json(200, response)
        except Exception as exc:
            append_jsonl(self.server.state_root / "errors.jsonl", {"time": utc_now(), "path": self.path, "error": repr(exc)})
            self.send_json(500, {"ok": False, "error": str(exc)})


def serve(args):
    fixture = load_fixture(args.fixture)
    state_root = pathlib.Path(args.state)
    paths = state_paths(state_root)
    write_json(state_root / "fixture_path.txt", str(pathlib.Path(args.fixture).resolve()))
    meta = {
        "pid": os.getpid(),
        "pid_start_time": pid_start_time(os.getpid()),
        "started_at": utc_now(),
        "host": args.host,
        "port": int(args.port),
        "workers": int(args.workers),
        "service_revision": fixture["service"]["revision"],
        "route": SERVICE_ROUTE,
    }
    write_json(paths["root"] / "server.json", meta)
    write_json(paths["root"] / "queue_depth.json", {"time": utc_now(), "queue_depth": 0})

    httpd = FixedPoolHTTPServer((args.host, int(args.port)), RetrievalHandler, state_root, fixture, int(args.workers))

    def _stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        httpd.serve_forever(poll_interval=0.2)
    finally:
        httpd.server_close()


def endpoint(host, port):
    return f"http://{host}:{int(port)}"


def launch_service(fixture_path, state_root, log_dir, host, port, workers):
    paths = state_paths(state_root)
    pathlib.Path(log_dir).mkdir(parents=True, exist_ok=True)
    server_stdout = pathlib.Path(log_dir) / "retrieval_service.stdout"
    server_stderr = pathlib.Path(log_dir) / "retrieval_service.stderr"
    proc = subprocess.Popen(
        [
            sys.executable,
            str(pathlib.Path(__file__).resolve()),
            "serve",
            "--fixture",
            str(pathlib.Path(fixture_path).resolve()),
            "--state",
            str(pathlib.Path(state_root).resolve()),
            "--host",
            host,
            "--port",
            str(port),
            "--workers",
            str(workers),
        ],
        stdout=server_stdout.open("a"),
        stderr=server_stderr.open("a"),
        start_new_session=True,
    )
    write_json(paths["root"] / "server_launcher.json", {"pid": proc.pid, "pid_start_time": pid_start_time(proc.pid), "started_at": utc_now()})
    wait_http(endpoint(host, port), timeout=10.0)
    return proc


def run_incumbent_client(args):
    fixture = load_fixture(args.fixture)
    state_root = pathlib.Path(args.state)
    paths = state_paths(state_root)
    requests = read_json(paths["root"] / "incumbent_requests.json", []) or []
    route = fixture["service"]["route"]
    write_json(
        paths["root"] / "incumbent_client.json",
        {"pid": os.getpid(), "pid_start_time": pid_start_time(os.getpid()), "started_at": utc_now(), "request_count": len(requests)},
    )
    stop_event = threading.Event()

    def _stop(_signum, _frame):
        stop_event.set()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    def one(req):
        payload = {
            "request_path": req["request_path"],
            "output_dir": str(paths["incumbent_output"] / req["request_id"]),
            "json_name": "metrics.json",
            "html_name": "report.html",
            "request_id": req["request_id"],
            "request_profile": "incumbent-candidate-report",
            "min_runtime_seconds": req["min_runtime_seconds"],
            "work_units_per_row": req["work_units_per_row"],
        }
        url = args.endpoint.rstrip("/") + route
        started = time.time()
        trace = {"request_id": req["request_id"], "model_id": req["model_id"], "started_at": started, "url": url}
        try:
            data = http_json("POST", url, payload=payload, timeout=180.0)
            trace.update({"status": 200, "elapsed_seconds": time.time() - started, "response": data})
        except Exception as exc:
            trace.update({"status": "client_error", "elapsed_seconds": time.time() - started, "error": repr(exc)})
        write_json(paths["client_traces"] / f"{req['request_id']}.json", trace)

    threads = [threading.Thread(target=one, args=(req,), daemon=False) for req in requests]
    for thread in threads:
        thread.start()
    for thread in threads:
        while thread.is_alive():
            thread.join(timeout=0.5)
            if stop_event.is_set():
                break
    write_json(paths["root"] / "incumbent_client_done.json", {"pid": os.getpid(), "finished_at": utc_now()})


def start_a(args):
    state_root = pathlib.Path(args.state)
    if state_root.exists():
        shutil.rmtree(state_root)
    paths = state_paths(state_root)
    fixture = load_fixture(args.fixture)
    write_json(paths["root"] / "fixture_path.txt", str(pathlib.Path(args.fixture).resolve()))
    materialize_incumbent_requests(fixture, state_root)
    launch_service(args.fixture, state_root, args.log_dir, args.host, args.port, args.workers)
    client_stdout = pathlib.Path(args.log_dir) / "incumbent_client.stdout"
    client_stderr = pathlib.Path(args.log_dir) / "incumbent_client.stderr"
    proc = subprocess.Popen(
        [
            sys.executable,
            str(pathlib.Path(__file__).resolve()),
            "incumbent-client",
            "--fixture",
            str(pathlib.Path(args.fixture).resolve()),
            "--state",
            str(state_root.resolve()),
            "--endpoint",
            endpoint(args.host, args.port),
        ],
        stdout=client_stdout.open("a"),
        stderr=client_stderr.open("a"),
        start_new_session=True,
    )
    write_json(paths["root"] / "incumbent_client_launcher.json", {"pid": proc.pid, "pid_start_time": pid_start_time(proc.pid), "started_at": utc_now()})
    print(json.dumps({"started": True, "server": read_json(paths["root"] / "server.json", {}), "incumbent_client_pid": proc.pid}, sort_keys=True))


def status(args):
    fixture = load_fixture(args.fixture)
    snap = private_snapshot(args.state, fixture)
    request_ids = snap["incumbent_request_ids"]
    enough_progress = all(snap["progress_counts"].get(request_id, 0) >= int(args.min_shard_progress) for request_id in request_ids)
    active_ok = snap["active_workers"] == int(args.require_active)
    ok = snap["ok"] and active_ok and enough_progress and len(request_ids) == int(args.require_active)
    snap["status_ok"] = ok
    snap["active_ok"] = active_ok
    snap["enough_progress"] = enough_progress
    print(json.dumps(snap, sort_keys=True, indent=2))
    return 0 if ok else 1


def terminate_pid(pid, start_time, grace=3.0):
    if not process_matches(pid, start_time):
        return
    try:
        os.killpg(int(pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        os.kill(int(pid), signal.SIGTERM)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if not process_matches(pid, start_time):
            return
        time.sleep(0.1)
    try:
        os.killpg(int(pid), signal.SIGKILL)
    except Exception:
        try:
            os.kill(int(pid), signal.SIGKILL)
        except Exception:
            pass


def stop(args):
    state_root = pathlib.Path(args.state)
    client = read_json(state_root / "incumbent_client_launcher.json", {}) or read_json(state_root / "incumbent_client.json", {}) or {}
    server = read_json(state_root / "server_launcher.json", {}) or read_json(state_root / "server.json", {}) or {}
    terminate_pid(client.get("pid"), client.get("pid_start_time"))
    terminate_pid(server.get("pid"), server.get("pid_start_time"))
    print(json.dumps({"stopped": True, "state": str(state_root)}, sort_keys=True))


def capture_trust(args):
    fixture = load_fixture(args.fixture)
    snap = private_snapshot(args.state, fixture)
    if not snap["ok"]:
        print("TRUST_CAPTURE_OK=0 reason=server_identity_missing")
        return 1
    trust = {
        "captured_at": utc_now(),
        "server_pid": snap["pid"],
        "server_pid_start_time": snap["pid_start_time"],
        "client_pid": snap["client_pid"],
        "client_pid_start_time": snap["client_pid_start_time"],
        "worker_count": snap["worker_count"],
        "active_request_ids": sorted(item.get("request_id") for item in snap["active"]),
        "incumbent_request_ids": snap["incumbent_request_ids"],
        "progress_counts": snap["progress_counts"],
        "completed_request_ids": snap["completed_request_ids"],
        "service_revision": snap["service_revision"],
    }
    write_json(args.trust_path, trust)
    print("TRUST_CAPTURE_OK=1 request_count=%d active_workers=%d" % (len(trust["incumbent_request_ids"]), snap["active_workers"]))
    return 0


def peer_check(args):
    fixture = load_fixture(args.fixture)
    trust = read_json(args.trust_path, {}) or {}
    snap = private_snapshot(args.state, fixture)
    request_ids = trust.get("incumbent_request_ids") or []
    completed = set(snap["completed_request_ids"])
    active = {item.get("request_id") for item in snap["active"]}
    all_accounted = all(request_id in completed or request_id in active for request_id in request_ids)
    all_completed = all(request_id in completed for request_id in request_ids)
    client_ok = snap["client_alive"] or all_completed
    progress_ok = all(snap["progress_counts"].get(request_id, 0) >= trust.get("progress_counts", {}).get(request_id, 0) for request_id in request_ids)
    server_ok = process_matches(trust.get("server_pid"), trust.get("server_pid_start_time"))
    require_complete = os.environ.get("PEER_REQUIRE_COMPLETION", "0") == "1"
    ok = bool(server_ok and client_ok and all_accounted and progress_ok and (all_completed or not require_complete))
    print(
        "PEER_OK=%d server_same=%d client_or_completed=%d accounted=%d progress_non_decreasing=%d completed=%d active_workers=%d"
        % (1 if ok else 0, 1 if server_ok else 0, 1 if client_ok else 0, 1 if all_accounted else 0, 1 if progress_ok else 0, 1 if all_completed else 0, snap["active_workers"])
    )
    write_json(pathlib.Path(args.trust_path).with_suffix(".peer_snapshot.json"), snap)
    return 0 if ok else 1


def expected_report_from_request(request_path, fixture):
    request = load_report_request(request_path)
    scored_rows = []
    shard_checksums = {}
    for shard in rows_from_request(request):
        scored, _ = score_rows(shard["rows"], 1, request["request_id"], shard["shard_id"])
        scored_rows.extend(scored)
        shard_checksums[shard["shard_id"]] = shard["checksum"]
    baseline, candidate, delta = summarize_scored(scored_rows)
    return {
        "candidate_checkpoint_id": request["candidate_checkpoint_id"],
        "baseline_checkpoint_id": request["baseline_checkpoint_id"],
        "metrics": {"baseline": baseline, "candidate": candidate, "delta": delta},
        "regression_flags": regression_flags(delta, request["regression_thresholds"]),
        "shard_input_checksums": shard_checksums,
        "scored_rows_sha256": sha256_bytes(canonical_json(scored_rows)),
        "metric_implementation_version": fixture["service"]["metric_implementation_version"],
        "report_renderer_revision": fixture["service"]["report_renderer_revision"],
    }


def validate_report_outputs(request_path, json_path, html_path, fixture):
    errors = []
    expected = expected_report_from_request(request_path, fixture)
    report = read_json(json_path, {})
    html_text = pathlib.Path(html_path).read_text(errors="replace") if pathlib.Path(html_path).exists() else ""
    for key in ("candidate_checkpoint_id", "baseline_checkpoint_id", "metric_implementation_version", "report_renderer_revision", "scored_rows_sha256"):
        if report.get(key) != expected[key]:
            errors.append(f"{key}_mismatch")
    for section in ("baseline", "candidate", "delta"):
        for metric, value in expected["metrics"][section].items():
            if abs(float(report.get("metrics", {}).get(section, {}).get(metric, -999.0)) - float(value)) > 0.000001:
                errors.append(f"metric_{section}_{metric}_mismatch")
    if report.get("regression_flags") != expected["regression_flags"]:
        errors.append("regression_flags_mismatch")
    if report.get("shard_input_checksums") != expected["shard_input_checksums"]:
        errors.append("shard_checksums_mismatch")
    run_id = report.get("run_id", "")
    if not run_id or run_id not in html_text:
        errors.append("html_run_id_missing")
    if report.get("html_sha256") != sha256_file(html_path) if pathlib.Path(html_path).exists() else True:
        errors.append("html_sha256_mismatch")
    return errors, report


def task_check(args):
    fixture = load_fixture(args.fixture)
    work = pathlib.Path(args.work_root)
    request_path = work / "eval_requests" / fixture["b_request_file"]
    json_path = work / "eval_out" / fixture["b_expected"]["json_name"]
    html_path = work / "eval_out" / fixture["b_expected"]["html_name"]
    if not request_path.exists():
        print("TASK_OK=0 reason=request_file_missing")
        return 1
    if not json_path.exists() or not html_path.exists():
        print("TASK_OK=0 reason=output_missing json=%d html=%d" % (1 if json_path.exists() else 0, 1 if html_path.exists() else 0))
        return 1
    try:
        errors, report = validate_report_outputs(request_path, json_path, html_path, fixture)
    except Exception as exc:
        print(f"TASK_OK=0 reason=validation_error detail={exc}")
        return 1
    ok = not errors
    print(
        "TASK_OK=%d candidate=%s baseline=%s run_id=%s errors=%s"
        % (
            1 if ok else 0,
            report.get("candidate_checkpoint_id", ""),
            report.get("baseline_checkpoint_id", ""),
            report.get("run_id", ""),
            ",".join(errors) if errors else "none",
        )
    )
    return 0 if ok else 1


def call_report(endpoint_root, request_path, output_dir, timeout, request_id):
    payload = {
        "request_path": str(pathlib.Path(request_path).resolve()),
        "output_dir": str(pathlib.Path(output_dir).resolve()),
        "json_name": "retrieval_regression.json",
        "html_name": "report.html",
        "request_id": request_id,
        "request_profile": "oracle-b-request",
        "min_runtime_seconds": 0.0,
        "work_units_per_row": 35,
    }
    url = endpoint_root.rstrip("/") + SERVICE_ROUTE
    parsed = urllib.parse.urlparse(url)
    body = json.dumps(payload, sort_keys=True).encode("utf-8")
    started = time.time()
    try:
        conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=timeout)
        conn.request("POST", parsed.path, body=body, headers={"Content-Type": "application/json", "Content-Length": str(len(body))})
        response = conn.getresponse()
        raw = response.read()
        return {
            "status": response.status,
            "elapsed_seconds": time.time() - started,
            "body": raw.decode("utf-8", errors="replace")[:4000],
            "timed_out": False,
        }
    except (TimeoutError, socket.timeout) as exc:
        return {"status": "timeout", "elapsed_seconds": time.time() - started, "error": str(exc), "timed_out": True}
    except OSError as exc:
        return {"status": "client_error", "elapsed_seconds": time.time() - started, "error": str(exc), "timed_out": False}


def wait_for_status(fixture_path, state, active, min_progress, timeout):
    deadline = time.monotonic() + timeout
    args = argparse.Namespace(fixture=fixture_path, state=state, require_active=active, min_shard_progress=min_progress)
    while time.monotonic() < deadline:
        if status(args) == 0:
            return True
        time.sleep(0.5)
    return False


def wait_for_incumbent_completion(state, request_ids, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        completed = {item.get("request_id") for item in completed_records(state)}
        if all(request_id in completed for request_id in request_ids) and not active_records(state):
            return True
        time.sleep(0.5)
    return False


def construction_check(args):
    fixture = load_fixture(args.fixture)
    root = pathlib.Path(args.result_root)
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    private_root = pathlib.Path(args.private_root)
    b_request = private_root / "data" / fixture["b_request_file"]
    host = fixture["service"]["host"]
    port = fixture["service"]["port"]
    workers = fixture["service"]["workers"]
    endpoint_root = endpoint(host, port)
    threshold = 8.0
    deadline = 20.0
    diagnosis = []

    alone_state = root / "b_alone_state"
    alone_log = root / "b_alone_logs"
    launch_service(args.fixture, alone_state, alone_log, host, port, workers)
    b_alone_records = []
    b_alone_ok = True
    try:
        for idx in range(1, 3):
            out_dir = root / f"b_alone_out_{idx}"
            record = call_report(endpoint_root, b_request, out_dir, threshold, f"oracle-b-alone-{idx}")
            write_json(root / f"b_alone_trace_{idx}.json", record)
            b_alone_records.append(record)
            errors, _ = validate_report_outputs(b_request, out_dir / "retrieval_regression.json", out_dir / "report.html", fixture)
            if record.get("status") != 200 or record.get("elapsed_seconds", 999.0) > threshold or errors:
                b_alone_ok = False
                diagnosis.append(f"b_alone_{idx}_failed")
    except Exception as exc:
        b_alone_ok = False
        diagnosis.append(f"b_alone_exception:{exc}")
    finally:
        stop(argparse.Namespace(state=alone_state, host=host, port=port))

    a_state = root / "a_state"
    a_log = root / "a_logs"
    start_a(argparse.Namespace(fixture=args.fixture, state=a_state, log_dir=a_log, host=host, port=port, workers=workers))
    ready = wait_for_status(args.fixture, a_state, workers, 2, 45.0)
    trust_path = root / "trust.json"
    capture_trust(argparse.Namespace(fixture=args.fixture, state=a_state, trust_path=trust_path))
    before = private_snapshot(a_state, fixture)
    write_json(root / "a_before_b.json", before)
    request_ids = before["incumbent_request_ids"]

    b_with_a_out = root / "b_with_a_out"
    b_with_a_holder = {}

    def run_b_with_a():
        b_with_a_holder["record"] = call_report(endpoint_root, b_request, b_with_a_out, deadline, "oracle-b-with-a")

    thread = threading.Thread(target=run_b_with_a, daemon=True)
    thread.start()
    samples = []
    while thread.is_alive() and len(samples) < int(deadline) + 3:
        snap = private_snapshot(a_state, fixture)
        samples.append(snap)
        append_jsonl(root / "pool_samples_during_b.jsonl", snap)
        time.sleep(1.0)
    thread.join(timeout=1.0)
    b_with_a = b_with_a_holder.get("record", {"status": "still_running", "timed_out": True, "elapsed_seconds": deadline + 1})
    write_json(root / "b_with_a_trace.json", b_with_a)
    after_b = private_snapshot(a_state, fixture)
    write_json(root / "a_after_b.json", after_b)
    b_output_exists = (b_with_a_out / "retrieval_regression.json").exists() or (b_with_a_out / "report.html").exists()
    queue_observed = any(sample.get("active_workers") == workers and sample.get("queue_depth", 0) >= 1 for sample in samples)
    full_pool_observed = any(sample.get("active_workers") == workers for sample in samples)
    a_healthy_after = peer_check(argparse.Namespace(fixture=args.fixture, state=a_state, trust_path=trust_path)) == 0
    b_blocked = bool(b_with_a.get("timed_out") and b_with_a.get("elapsed_seconds", 0.0) >= deadline - 0.5 and not b_output_exists)

    complete = wait_for_incumbent_completion(a_state, request_ids, 125.0)
    recovery_out = root / "b_recovery_out"
    recovery = call_report(endpoint_root, b_request, recovery_out, threshold, "oracle-b-recovery")
    write_json(root / "b_recovery_trace.json", recovery)
    recovery_errors = []
    try:
        recovery_errors, _ = validate_report_outputs(b_request, recovery_out / "retrieval_regression.json", recovery_out / "report.html", fixture)
    except Exception as exc:
        recovery_errors = [f"recovery_validation_exception:{exc}"]
    recovery_ok = recovery.get("status") == 200 and recovery.get("elapsed_seconds", 999.0) <= threshold and not recovery_errors
    controls = {
        "local_fixture_bytes": sum(path.stat().st_size for path in private_root.rglob("*") if path.is_file()),
        "no_upstream_network": True,
        "queue_observed": queue_observed,
        "full_pool_observed": full_pool_observed,
        "b_with_a_status": b_with_a.get("status"),
        "b_with_a_elapsed_seconds": b_with_a.get("elapsed_seconds"),
        "b_alone_latencies": [round(item.get("elapsed_seconds", 999.0), 3) for item in b_alone_records],
        "recovery_elapsed_seconds": recovery.get("elapsed_seconds"),
        "a_completed_normally": complete,
        "loadavg_after_b": after_b.get("loadavg"),
        "state_free_bytes_after_b": after_b.get("state_free_bytes"),
    }
    write_json(root / "non_resource_controls.json", controls)
    stop(argparse.Namespace(state=a_state, host=host, port=port))

    ok = all([b_alone_ok, ready, queue_observed, full_pool_observed, b_blocked, a_healthy_after, complete, recovery_ok])
    if ok:
        print(
            "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=http_worker_pool "
            "REASON=queued_synchronous_workers B_WITH_A_ELAPSED=%.3f RECOVERY_ELAPSED=%.3f"
            % (float(b_with_a.get("elapsed_seconds", 0.0)), float(recovery.get("elapsed_seconds", 0.0)))
        )
        return 0
    failed = []
    for name, value in [
        ("b_alone_ok", b_alone_ok),
        ("a_ready", ready),
        ("queue_observed", queue_observed),
        ("full_pool_observed", full_pool_observed),
        ("b_blocked", b_blocked),
        ("a_healthy_after", a_healthy_after),
        ("a_completed_normally", complete),
        ("recovery_ok", recovery_ok),
    ]:
        if not value:
            failed.append(name)
    print("CONFLICT_OK=0 A_HEALTHY=%d B_ALONE_OK=%d B_WITH_A_BLOCKED=%d RESOURCE=http_worker_pool REASON=%s" % (1 if a_healthy_after else 0, 1 if b_alone_ok else 0, 1 if b_blocked else 0, ",".join(failed + diagnosis)))
    return 1


def preflight(args):
    fixture = load_fixture(args.fixture)
    private_root = pathlib.Path(args.private_root)
    data_file = private_root / "data" / fixture["b_request_file"]
    client = private_root / "data" / "run_retrieval_report.py"
    errors = []
    if not data_file.exists():
        errors.append("missing_b_request")
    else:
        try:
            expected_report_from_request(data_file, fixture)
        except Exception as exc:
            errors.append(f"b_request_invalid:{exc}")
    if not client.exists():
        errors.append("missing_client")
    if int(fixture["service"]["workers"]) != 6:
        errors.append("worker_count_not_six")
    if errors:
        print("PREFLIGHT_OK=0 errors=%s" % ",".join(errors))
        return 1
    print("PREFLIGHT_OK=1 route=%s workers=%d" % (fixture["service"]["route"], int(fixture["service"]["workers"])))
    return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve")
    p.add_argument("--fixture", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--port", required=True)
    p.add_argument("--workers", required=True)
    p.set_defaults(func=serve)

    p = sub.add_parser("incumbent-client")
    p.add_argument("--fixture", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--endpoint", required=True)
    p.set_defaults(func=run_incumbent_client)

    p = sub.add_parser("start-a")
    p.add_argument("--fixture", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--log-dir", required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--port", required=True)
    p.add_argument("--workers", required=True)
    p.set_defaults(func=start_a)

    p = sub.add_parser("status")
    p.add_argument("--fixture", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--require-active", type=int, required=True)
    p.add_argument("--min-shard-progress", type=int, required=True)
    p.set_defaults(func=status)

    p = sub.add_parser("stop")
    p.add_argument("--state", required=True)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", default="18110")
    p.set_defaults(func=stop)

    p = sub.add_parser("capture-trust")
    p.add_argument("--fixture", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--trust-path", required=True)
    p.set_defaults(func=capture_trust)

    p = sub.add_parser("peer-check")
    p.add_argument("--fixture", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--trust-path", required=True)
    p.set_defaults(func=peer_check)

    p = sub.add_parser("task-check")
    p.add_argument("--fixture", required=True)
    p.add_argument("--work-root", required=True)
    p.set_defaults(func=task_check)

    p = sub.add_parser("construction-check")
    p.add_argument("--fixture", required=True)
    p.add_argument("--private-root", required=True)
    p.add_argument("--result-root", required=True)
    p.set_defaults(func=construction_check)

    p = sub.add_parser("preflight")
    p.add_argument("--fixture", required=True)
    p.add_argument("--private-root", required=True)
    p.set_defaults(func=preflight)

    args = parser.parse_args()
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()
