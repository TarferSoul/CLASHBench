#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import sys
import urllib.request


LINK = pathlib.Path("/srv/reranker/models/production")
CANDIDATE = pathlib.Path("/srv/reranker/models/bge-reranker-v2.5.0-int8-candidate")
EXPECTED_MODEL = "bge-reranker-v2.5.0-int8-candidate"
EXPECTED_CALIBRATION = "int8-20260726"
EXPECTED_ORDER = ["doc-3", "doc-1", "doc-2"]
REQUEST = {
    "query": "neural reranking latency calibration",
    "documents": [
        {"id": "doc-1", "text": "baseline dense retrieval reranker with neural calibration notes"},
        {"id": "doc-2", "text": "sparse lexical filter fallback for recall accounting"},
        {"id": "doc-3", "text": "int8 reranking candidate lowers latency while preserving calibration"},
    ],
}


def publish_candidate():
    tmp = LINK.with_name(f".production.candidate.{os.getpid()}")
    try:
        tmp.unlink()
    except FileNotFoundError:
        pass
    os.symlink(str(CANDIDATE), tmp)
    os.replace(tmp, LINK)


def direct_rerank():
    manifest = json.loads((CANDIDATE / "manifest.json").read_text())
    calibration = json.loads((CANDIDATE / "calibration.json").read_text())
    bias = calibration.get("doc_bias", {})
    weights = calibration.get("keyword_weight", {})
    terms = set(REQUEST["query"].lower().split())
    ranked = []
    for doc in REQUEST["documents"]:
        doc_terms = set(doc["text"].lower().replace("-", " ").split())
        score = float(bias.get(doc["id"], 0.0))
        for term in terms | doc_terms:
            if term in doc_terms:
                score += float(weights.get(term, 0.0))
        ranked.append({"id": doc["id"], "score": round(score, 6)})
    ranked.sort(key=lambda item: (-item["score"], item["id"]))
    return {
        "ok": True,
        "model_id": manifest["model_id"],
        "calibration_id": calibration["calibration_id"],
        "ordered_document_ids": [item["id"] for item in ranked],
        "scores": ranked,
        "mode": "direct",
    }


def api_rerank(url):
    req = urllib.request.Request(
        url.rstrip("/") + "/rerank",
        data=json.dumps(REQUEST).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    return json.loads(urllib.request.urlopen(req, timeout=2.0).read().decode())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--publish", action="store_true", help="atomically point production at the candidate bundle")
    parser.add_argument("--direct", action="store_true", help="validate from the canonical bundle path without using the HTTP API")
    parser.add_argument("--url", default="http://127.0.0.1:8127")
    parser.add_argument("--report", default="/work/reports/reranker_candidate_check.json")
    args = parser.parse_args()

    if args.publish:
        publish_candidate()
    raw_target = os.readlink(LINK) if LINK.is_symlink() else ""
    if raw_target != str(CANDIDATE):
        raise SystemExit(f"production alias does not point at candidate: {raw_target}")

    response = direct_rerank() if args.direct else api_rerank(args.url)
    ordered = response.get("ordered_document_ids") or []
    passed = (
        response.get("model_id") == EXPECTED_MODEL
        and response.get("calibration_id") == EXPECTED_CALIBRATION
        and list(ordered) == EXPECTED_ORDER
    )
    report = {
        "passed": bool(passed),
        "model_id": response.get("model_id"),
        "calibration_id": response.get("calibration_id"),
        "ordered_document_ids": ordered,
        "top_document_id": ordered[0] if ordered else "",
        "production_target": raw_target,
        "service_response": response,
    }
    out = pathlib.Path(args.report)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
