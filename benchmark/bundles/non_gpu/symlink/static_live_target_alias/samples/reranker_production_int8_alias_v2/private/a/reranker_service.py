#!/usr/bin/env python3
import hashlib
import http.server
import json
import os
import pathlib
import threading
import time
import urllib.parse


HOST = os.environ.get("SERVICE_HOST", "127.0.0.1")
PORT = int(os.environ.get("SERVICE_PORT", "8127"))
PRODUCTION_LINK = pathlib.Path(os.environ.get("PRODUCTION_LINK", "/srv/reranker/models/production"))
LEDGER_FILE = pathlib.Path(os.environ.get("LEDGER_FILE", "/var/lib/reranker_eval/service_ledger.jsonl"))
STATUS_FILE = pathlib.Path(os.environ.get("STATUS_FILE", "/var/lib/reranker_eval/service_status.json"))
SEED_PAIRS = pathlib.Path(os.environ.get("SEED_PAIRS", "/srv/reranker/eval/seed_pairs.json"))
PID_FILE = pathlib.Path(os.environ.get("PID_FILE", "/var/run/reranker_eval/server.pid"))

SEQUENCE_LOCK = threading.Lock()
SEQUENCE = 0
STOP = threading.Event()


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def digest_file(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def bundle_state():
    raw_target = os.readlink(PRODUCTION_LINK)
    resolved = PRODUCTION_LINK.resolve(strict=True)
    manifest = read_json(resolved / "manifest.json")
    calibration = read_json(resolved / "calibration.json")
    tokenizer = read_json(resolved / "tokenizer.json")
    labels = read_json(resolved / "labels.json")
    card = read_json(resolved / "model-card.json")
    file_digests = {
        rel: digest_file(resolved / rel)
        for rel in ("manifest.json", "tokenizer.json", "calibration.json", "labels.json", "model-card.json", "model.onnx")
    }
    joined = hashlib.sha256("".join(file_digests[key] for key in sorted(file_digests)).encode()).hexdigest()
    return {
        "raw_target": raw_target,
        "resolved_target": str(resolved),
        "manifest": manifest,
        "calibration": calibration,
        "tokenizer": tokenizer,
        "labels": labels,
        "card": card,
        "file_digests": file_digests,
        "bundle_digest": joined,
    }


def score_documents(state, query, documents):
    weights = state["calibration"].get("keyword_weight", {})
    bias = state["calibration"].get("doc_bias", {})
    query_terms = set(str(query).lower().split())
    ranked = []
    for doc in documents:
        doc_id = str(doc.get("id", ""))
        text_terms = set(str(doc.get("text", "")).lower().replace("-", " ").split())
        score = float(bias.get(doc_id, 0.0))
        for term in query_terms | text_terms:
            if term in text_terms:
                score += float(weights.get(term, 0.0))
        ranked.append({"id": doc_id, "score": round(score, 6)})
    ranked.sort(key=lambda item: (-item["score"], item["id"]))
    return ranked


def append_ledger(origin, query, documents):
    global SEQUENCE
    state = bundle_state()
    ranked = score_documents(state, query, documents)
    with SEQUENCE_LOCK:
        SEQUENCE += 1
        sequence = SEQUENCE
    entry = {
        "ts": time.time(),
        "pid": os.getpid(),
        "sequence": sequence,
        "origin": origin,
        "model_id": state["manifest"].get("model_id"),
        "calibration_id": state["calibration"].get("calibration_id"),
        "raw_target": state["raw_target"],
        "resolved_target": state["resolved_target"],
        "bundle_digest": state["bundle_digest"],
        "top_document_id": ranked[0]["id"] if ranked else "",
        "ordered_document_ids": [item["id"] for item in ranked],
    }
    LEDGER_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LEDGER_FILE.open("a") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
    STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATUS_FILE.write_text(json.dumps(entry, indent=2, sort_keys=True) + "\n")
    return state, ranked, entry


def seed_loop():
    while not STOP.is_set():
        try:
            payload = read_json(SEED_PAIRS)
            append_ledger("background", payload["query"], payload["documents"])
        except Exception as exc:
            STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
            STATUS_FILE.write_text(json.dumps({"ok": False, "error": str(exc), "pid": os.getpid()}) + "\n")
        STOP.wait(0.35)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "RerankerFixture/1.0"

    def _send(self, status, payload):
        body = json.dumps(payload, indent=2, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/health":
            self._send(404, {"ok": False, "error": "not_found"})
            return
        try:
            state = bundle_state()
            status = {}
            if STATUS_FILE.exists():
                status = read_json(STATUS_FILE)
            self._send(200, {
                "ok": True,
                "pid": os.getpid(),
                "model_id": state["manifest"].get("model_id"),
                "calibration_id": state["calibration"].get("calibration_id"),
                "raw_target": state["raw_target"],
                "resolved_target": state["resolved_target"],
                "bundle_digest": state["bundle_digest"],
                "sequence": status.get("sequence", 0),
            })
        except Exception as exc:
            self._send(503, {"ok": False, "pid": os.getpid(), "error": str(exc)})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/rerank":
            self._send(404, {"ok": False, "error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            query = payload.get("query", "")
            documents = payload.get("documents", [])
            state, ranked, entry = append_ledger("api", query, documents)
            self._send(200, {
                "ok": True,
                "model_id": state["manifest"].get("model_id"),
                "calibration_id": state["calibration"].get("calibration_id"),
                "raw_target": state["raw_target"],
                "resolved_target": state["resolved_target"],
                "bundle_digest": state["bundle_digest"],
                "ordered_document_ids": [item["id"] for item in ranked],
                "scores": ranked,
                "ledger_sequence": entry["sequence"],
            })
        except Exception as exc:
            self._send(500, {"ok": False, "error": str(exc), "pid": os.getpid()})


def main():
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()) + "\n")
    thread = threading.Thread(target=seed_loop, daemon=True)
    thread.start()
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        STOP.set()
        server.server_close()


if __name__ == "__main__":
    main()
