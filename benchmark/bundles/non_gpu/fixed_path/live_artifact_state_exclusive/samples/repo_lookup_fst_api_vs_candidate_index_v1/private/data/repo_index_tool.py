#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import time


MAGIC = "FSTIDXv1"
TOKEN_RE = re.compile(r"[a-z0-9_]+")


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def file_sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tokenize(text):
    return TOKEN_RE.findall(str(text).lower())


def load_docs(path):
    docs = []
    with pathlib.Path(path).open("r", encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {exc}") from exc
            doc_id = str(row.get("doc_id") or "").strip()
            title = str(row.get("title") or "").strip()
            body = str(row.get("body") or "").strip()
            tags = row.get("tags") or []
            if not doc_id or not title or not body or not isinstance(tags, list):
                raise SystemExit(f"{path}:{lineno}: doc_id, title, body, and tags are required")
            docs.append(
                {
                    "doc_id": doc_id,
                    "title": title,
                    "tags": [str(tag) for tag in tags],
                    "body": body,
                }
            )
    if not docs:
        raise SystemExit(f"{path}: no documents found")
    docs.sort(key=lambda item: item["doc_id"])
    return docs


def dataset_digest(docs):
    return hashlib.sha256(canonical_json(docs).encode("utf-8")).hexdigest()


def build_payload(docs, dataset_id, schema_version, revision):
    postings = {}
    for doc in docs:
        weighted = []
        weighted.extend(tokenize(doc["title"]) * 5)
        weighted.extend(tokenize(" ".join(doc["tags"])) * 3)
        weighted.extend(tokenize(doc["body"]))
        counts = {}
        for token in weighted:
            counts[token] = counts.get(token, 0) + 1
        for token, score in counts.items():
            postings.setdefault(token, []).append([doc["doc_id"], score])
    for values in postings.values():
        values.sort(key=lambda pair: (-pair[1], pair[0]))
    return {
        "schema_version": schema_version,
        "dataset_id": dataset_id,
        "revision": revision,
        "dataset_digest": dataset_digest(docs),
        "document_count": len(docs),
        "documents": docs,
        "postings": dict(sorted(postings.items())),
    }


def write_index(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = MAGIC + "\n" + canonical_json(payload) + "\n"
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_index(path):
    path = pathlib.Path(path)
    data = path.read_text(encoding="utf-8")
    first, _, rest = data.partition("\n")
    if first != MAGIC:
        raise ValueError(f"{path}: missing {MAGIC} header")
    payload = json.loads(rest)
    if payload.get("schema_version") != 3:
        raise ValueError(f"{path}: unsupported schema_version={payload.get('schema_version')!r}")
    if payload.get("document_count") != len(payload.get("documents", [])):
        raise ValueError(f"{path}: document_count mismatch")
    expected = dataset_digest(payload["documents"])
    if payload.get("dataset_digest") != expected:
        raise ValueError(f"{path}: dataset_digest mismatch")
    return payload


def query_payload(payload, query, topk):
    scores = {}
    for token in tokenize(query):
        for doc_id, score in payload.get("postings", {}).get(token, []):
            scores[doc_id] = scores.get(doc_id, 0) + int(score)
    ranked = sorted(scores.items(), key=lambda pair: (-pair[1], pair[0]))
    return [doc_id for doc_id, _ in ranked[:topk]]


def load_manifest(path):
    with pathlib.Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_index(path, manifest_path):
    manifest = load_manifest(manifest_path)
    payload = read_index(path)
    failures = []
    if payload.get("dataset_id") != manifest.get("dataset_id"):
        failures.append(f"dataset_id={payload.get('dataset_id')!r}")
    if payload.get("schema_version") != int(manifest.get("schema_version", -1)):
        failures.append(f"schema_version={payload.get('schema_version')!r}")
    if payload.get("dataset_digest") != manifest.get("dataset_digest"):
        failures.append("dataset_digest")
    checks = []
    for item in manifest.get("sentinel_queries", []):
        query = item["query"]
        expected = item["expected_doc_ids"]
        actual = query_payload(payload, query, len(expected))
        ok = actual == expected
        checks.append({"query": query, "expected": expected, "actual": actual, "ok": ok})
        if not ok:
            failures.append(f"query:{query}")
    return {
        "ok": not failures,
        "failures": failures,
        "path": str(path),
        "file_sha256": file_sha256(path),
        "dataset_id": payload.get("dataset_id"),
        "schema_version": payload.get("schema_version"),
        "dataset_digest": payload.get("dataset_digest"),
        "document_count": payload.get("document_count"),
        "checks": checks,
    }


def maybe_write_report(path, payload):
    if not path:
        return
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def cmd_build(args):
    docs = load_docs(args.input)
    payload = build_payload(docs, args.dataset_id, args.schema_version, args.revision)
    write_index(args.output, payload)
    report = {
        "ok": True,
        "operation": "build",
        "output": args.output,
        "dataset_id": args.dataset_id,
        "schema_version": args.schema_version,
        "revision": args.revision,
        "dataset_digest": payload["dataset_digest"],
        "file_sha256": file_sha256(args.output),
        "document_count": len(docs),
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    maybe_write_report(args.report, report)
    print(json.dumps(report, sort_keys=True))
    return 0


def cmd_inspect(args):
    payload = read_index(args.path)
    report = {
        "ok": True,
        "path": args.path,
        "dataset_id": payload.get("dataset_id"),
        "schema_version": payload.get("schema_version"),
        "revision": payload.get("revision"),
        "dataset_digest": payload.get("dataset_digest"),
        "file_sha256": file_sha256(args.path),
        "document_count": payload.get("document_count"),
    }
    print(json.dumps(report, sort_keys=True, indent=2 if args.pretty else None))
    return 0


def cmd_query(args):
    payload = read_index(args.path)
    actual = query_payload(payload, args.query, args.topk)
    report = {"ok": True, "query": args.query, "topk": args.topk, "doc_ids": actual}
    if args.expect:
        expected = [item.strip() for item in args.expect.split(",") if item.strip()]
        report["expected_doc_ids"] = expected
        report["ok"] = actual[: len(expected)] == expected
    print(json.dumps(report, sort_keys=True))
    return 0 if report["ok"] else 1


def cmd_validate(args):
    report = validate_index(args.path, args.manifest)
    print(json.dumps(report, sort_keys=True, indent=2 if args.pretty else None))
    return 0 if report["ok"] else 1


def cmd_digest_corpus(args):
    docs = load_docs(args.input)
    print(dataset_digest(docs))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Build and validate FSTIDXv1 repository lookup indexes")
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build")
    build.add_argument("--input", required=True)
    build.add_argument("--output", required=True)
    build.add_argument("--dataset-id", required=True)
    build.add_argument("--schema-version", type=int, default=3)
    build.add_argument("--revision", default="candidate")
    build.add_argument("--report", default="")
    build.set_defaults(func=cmd_build)

    inspect = sub.add_parser("inspect")
    inspect.add_argument("--path", required=True)
    inspect.add_argument("--pretty", action="store_true")
    inspect.set_defaults(func=cmd_inspect)

    query = sub.add_parser("query")
    query.add_argument("--path", required=True)
    query.add_argument("--query", required=True)
    query.add_argument("--topk", type=int, default=3)
    query.add_argument("--expect", default="")
    query.set_defaults(func=cmd_query)

    validate = sub.add_parser("validate")
    validate.add_argument("--path", required=True)
    validate.add_argument("--manifest", required=True)
    validate.add_argument("--pretty", action="store_true")
    validate.set_defaults(func=cmd_validate)

    digest = sub.add_parser("digest-corpus")
    digest.add_argument("--input", required=True)
    digest.set_defaults(func=cmd_digest_corpus)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:
        print(f"repo-index-tool: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
