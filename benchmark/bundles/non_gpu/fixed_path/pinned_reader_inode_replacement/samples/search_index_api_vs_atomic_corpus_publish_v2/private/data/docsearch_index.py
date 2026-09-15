#!/usr/bin/env python3
import argparse
import csv
import hashlib
import http.server
import json
import mmap
import os
import pathlib
import socketserver
import stat
import struct
import sys
import tempfile
import time
import urllib.parse


MAGIC = b"DFSTIDX1"


def write_json(path, payload):
    if not path:
        return
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(target) + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(target)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_corpus(path):
    with pathlib.Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {"term", "title", "body"}
        missing = sorted(required - set(reader.fieldnames or []))
        if missing:
            raise ValueError(f"missing corpus columns: {','.join(missing)}")
        entries = []
        seen = set()
        for row in reader:
            term = (row.get("term") or "").strip().lower()
            title = (row.get("title") or "").strip()
            body = (row.get("body") or "").strip()
            if not term or not title:
                raise ValueError("term and title are required")
            if term in seen:
                raise ValueError(f"duplicate term: {term}")
            seen.add(term)
            entries.append({"term": term, "title": title, "body": body})
    if not entries:
        raise ValueError("empty corpus")
    return sorted(entries, key=lambda item: item["term"])


def common_prefixes(terms):
    prefixes = {}
    for term in terms:
        for length in range(1, len(term) + 1):
            prefix = term[:length]
            prefixes.setdefault(prefix, 0)
            prefixes[prefix] += 1
    return prefixes


def pack_index(entries, dataset_id, version):
    terms = [entry["term"] for entry in entries]
    payload = {
        "entries": entries,
        "prefix_counts": common_prefixes(terms),
    }
    payload_bytes = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    header = {
        "format": "docsearch-fst-v1",
        "dataset_id": dataset_id,
        "version": int(version),
        "entry_count": len(entries),
        "terms_sha256": sha256_bytes("\n".join(terms).encode("utf-8")),
        "payload_sha256": sha256_bytes(payload_bytes),
    }
    header_bytes = json.dumps(header, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return MAGIC + struct.pack("!I", len(header_bytes)) + header_bytes + struct.pack("!I", len(payload_bytes)) + payload_bytes


def unpack_index_bytes(data):
    if len(data) < len(MAGIC) + 8 or not data.startswith(MAGIC):
        raise ValueError("bad_magic")
    offset = len(MAGIC)
    header_len = struct.unpack("!I", data[offset:offset + 4])[0]
    offset += 4
    if header_len <= 0 or offset + header_len + 4 > len(data):
        raise ValueError("bad_header_length")
    header = json.loads(data[offset:offset + header_len].decode("utf-8"))
    offset += header_len
    payload_len = struct.unpack("!I", data[offset:offset + 4])[0]
    offset += 4
    if payload_len <= 0 or offset + payload_len != len(data):
        raise ValueError("bad_payload_length")
    payload_bytes = data[offset:offset + payload_len]
    if sha256_bytes(payload_bytes) != header.get("payload_sha256"):
        raise ValueError("payload_digest_mismatch")
    payload = json.loads(payload_bytes.decode("utf-8"))
    entries = payload.get("entries") or []
    if len(entries) != int(header.get("entry_count", -1)):
        raise ValueError("entry_count_mismatch")
    terms = [entry.get("term", "") for entry in entries]
    if sha256_bytes("\n".join(terms).encode("utf-8")) != header.get("terms_sha256"):
        raise ValueError("terms_digest_mismatch")
    return {"header": header, "entries": entries, "prefix_counts": payload.get("prefix_counts") or {}}


def load_index(path):
    data = pathlib.Path(path).read_bytes()
    parsed = unpack_index_bytes(data)
    parsed["sha256"] = sha256_bytes(data)
    return parsed


def write_artifact(path, entries, dataset_id, version):
    data = pack_index(entries, dataset_id, version)
    with pathlib.Path(path).open("wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    return sha256_bytes(data), len(data)


def fsync_dir(path):
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def command_publish(args):
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "command": "publish",
        "input": args.input,
        "output": str(output),
        "dataset_id": args.dataset_id,
        "version": int(args.version),
        "ok": False,
        "publish_mode": "temp_fsync_rename",
    }
    try:
        entries = read_corpus(args.input)
        fd, tmp_name = tempfile.mkstemp(prefix=".docsearch-index-", suffix=".fst", dir=str(output.parent))
        os.close(fd)
        tmp_path = pathlib.Path(tmp_name)
        try:
            digest, size = write_artifact(tmp_path, entries, args.dataset_id, args.version)
            os.chmod(tmp_path, 0o644)
            os.replace(tmp_path, output)
            fsync_dir(output.parent)
            st = os.lstat(output)
            report.update(
                ok=True,
                entry_count=len(entries),
                sha256=digest,
                size=size,
                dev=st.st_dev,
                inode=st.st_ino,
            )
            write_json(args.report, report)
            print(
                f"PUBLISH_OK=1 output={output} dataset={args.dataset_id} "
                f"version={int(args.version)} entries={len(entries)} inode={st.st_ino}"
            )
            return 0
        finally:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass
    except Exception as exc:
        report.update(error=f"{type(exc).__name__}:{exc}")
        write_json(args.report, report)
        print(f"PUBLISH_OK=0 error={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1


def command_validate(args):
    index_path = pathlib.Path(args.index)
    report = {
        "command": "validate",
        "index": str(index_path),
        "expected_dataset": args.dataset_id,
        "ok": False,
    }
    errors = []
    try:
        st = os.lstat(index_path)
        if stat.S_ISLNK(st.st_mode):
            errors.append("index_is_symlink")
        if not stat.S_ISREG(st.st_mode):
            errors.append("index_not_regular")
    except FileNotFoundError:
        errors.append("index_missing")
        write_json(args.report, {**report, "errors": errors})
        print("VALIDATION_OK=0 reason=index_missing")
        return 1
    parsed = None
    try:
        parsed = load_index(index_path)
    except Exception as exc:
        errors.append(f"parse_failed:{type(exc).__name__}:{exc}")
    terms = {}
    if parsed:
        terms = {entry["term"]: entry for entry in parsed["entries"]}
        if parsed["header"].get("dataset_id") != args.dataset_id:
            errors.append("dataset_mismatch")
        if args.version is not None and int(parsed["header"].get("version", -1)) != int(args.version):
            errors.append("version_mismatch")
        for term in args.expect_term:
            if term.lower() not in terms:
                errors.append(f"missing_term:{term.lower()}")
        for term in args.expect_missing:
            if term.lower() in terms:
                errors.append(f"unexpected_term:{term.lower()}")
    report.update(
        ok=not errors,
        errors=errors,
        observed_dataset=(parsed or {}).get("header", {}).get("dataset_id"),
        observed_version=(parsed or {}).get("header", {}).get("version"),
        entry_count=len(terms),
        sha256=(parsed or {}).get("sha256"),
    )
    write_json(args.report, report)
    if errors:
        print(f"VALIDATION_OK=0 reason={','.join(errors)}")
        return 1
    print(
        f"VALIDATION_OK=1 index={index_path} dataset={args.dataset_id} "
        f"version={(parsed or {}).get('header', {}).get('version')} entries={len(terms)}"
    )
    return 0


def query_loaded(parsed, term):
    term = term.lower()
    exact = [entry for entry in parsed["entries"] if entry["term"] == term]
    prefix = [entry for entry in parsed["entries"] if entry["term"].startswith(term)]
    return exact or prefix[:5]


def command_query(args):
    try:
        parsed = load_index(args.index)
        matches = query_loaded(parsed, args.term)
        payload = {
            "ok": bool(matches),
            "dataset_id": parsed["header"].get("dataset_id"),
            "version": parsed["header"].get("version"),
            "term": args.term.lower(),
            "matches": matches,
            "sha256": parsed["sha256"],
        }
        print(json.dumps(payload, sort_keys=True))
        return 0 if matches else 2
    except Exception as exc:
        print(json.dumps({"ok": False, "term": args.term.lower(), "error": f"{type(exc).__name__}:{exc}"}, sort_keys=True))
        return 1


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class SearchService:
    def __init__(self, index_path, status_file, pid_file):
        self.index_path = pathlib.Path(index_path)
        self.status_file = pathlib.Path(status_file)
        self.pid_file = pathlib.Path(pid_file)
        self.fileobj = self.index_path.open("rb")
        self.fd = self.fileobj.fileno()
        self.map = mmap.mmap(self.fd, 0, access=mmap.ACCESS_READ)
        self.query_count = 0
        self.started_at = time.time()
        self.pid_file.parent.mkdir(parents=True, exist_ok=True)
        self.pid_file.write_text(str(os.getpid()) + "\n", encoding="utf-8")

    def mapped_bytes(self):
        return self.map[:]

    def parsed(self):
        data = self.mapped_bytes()
        parsed = unpack_index_bytes(data)
        parsed["sha256"] = sha256_bytes(data)
        return parsed

    def status(self):
        errors = []
        parsed = None
        try:
            parsed = self.parsed()
        except Exception as exc:
            errors.append(f"mapped_parse_failed:{type(exc).__name__}:{exc}")
        fd_stat = os.fstat(self.fd)
        canonical = None
        try:
            st = os.lstat(self.index_path)
            canonical = {"dev": st.st_dev, "inode": st.st_ino, "size": st.st_size}
        except Exception as exc:
            errors.append(f"canonical_stat_failed:{type(exc).__name__}:{exc}")
        fd_target = ""
        try:
            fd_target = os.readlink(f"/proc/{os.getpid()}/fd/{self.fd}")
        except OSError:
            pass
        payload = {
            "health": not errors,
            "pid": os.getpid(),
            "fd": self.fd,
            "fd_dev": fd_stat.st_dev,
            "fd_inode": fd_stat.st_ino,
            "fd_size": fd_stat.st_size,
            "fd_target": fd_target,
            "canonical": canonical,
            "dataset_id": (parsed or {}).get("header", {}).get("dataset_id"),
            "version": (parsed or {}).get("header", {}).get("version"),
            "sha256": (parsed or {}).get("sha256"),
            "entry_count": len((parsed or {}).get("entries", [])),
            "query_count": self.query_count,
            "started_at": self.started_at,
            "last_probe_epoch": time.time(),
            "errors": errors,
        }
        try:
            write_json(self.status_file, payload)
        except OSError:
            pass
        return payload

    def query(self, term):
        parsed = self.parsed()
        self.query_count += 1
        matches = query_loaded(parsed, term)
        status_payload = self.status()
        return {
            "ok": bool(matches),
            "dataset_id": parsed["header"].get("dataset_id"),
            "version": parsed["header"].get("version"),
            "term": term.lower(),
            "matches": matches,
            "service_pid": os.getpid(),
            "fd_inode": status_payload["fd_inode"],
            "canonical_inode": (status_payload.get("canonical") or {}).get("inode"),
        }


def command_serve(args):
    service = SearchService(args.index, args.status_file, args.pid_file)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *values):
            return

        def send_payload(self, status_code, payload):
            data = json.dumps(payload, sort_keys=True).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            parsed_url = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(parsed_url.query)
            try:
                if parsed_url.path == "/health":
                    payload = service.status()
                    self.send_payload(200 if payload.get("health") else 503, payload)
                    return
                if parsed_url.path == "/query":
                    term = (params.get("q") or [""])[0]
                    if not term:
                        self.send_payload(400, {"ok": False, "error": "missing_q"})
                        return
                    payload = service.query(term)
                    self.send_payload(200 if payload.get("ok") else 404, payload)
                    return
                self.send_payload(404, {"ok": False, "error": "not_found"})
            except Exception as exc:
                service.status()
                self.send_payload(500, {"ok": False, "error": f"{type(exc).__name__}:{exc}"})

    httpd = ThreadedServer((args.host, int(args.port)), Handler)
    service.status()
    httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="Compile, publish, validate, and serve compact docs search indexes.")
    sub = parser.add_subparsers(dest="command", required=True)

    publish = sub.add_parser("publish")
    publish.add_argument("--input", required=True)
    publish.add_argument("--output", required=True)
    publish.add_argument("--dataset-id", required=True)
    publish.add_argument("--version", required=True, type=int)
    publish.add_argument("--report", required=True)
    publish.set_defaults(func=command_publish)

    validate = sub.add_parser("validate")
    validate.add_argument("--index", required=True)
    validate.add_argument("--dataset-id", required=True)
    validate.add_argument("--version", type=int)
    validate.add_argument("--expect-term", action="append", default=[])
    validate.add_argument("--expect-missing", action="append", default=[])
    validate.add_argument("--report", required=True)
    validate.set_defaults(func=command_validate)

    query = sub.add_parser("query")
    query.add_argument("--index", required=True)
    query.add_argument("--term", required=True)
    query.set_defaults(func=command_query)

    serve = sub.add_parser("serve")
    serve.add_argument("--index", required=True)
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", required=True, type=int)
    serve.add_argument("--status-file", required=True)
    serve.add_argument("--pid-file", required=True)
    serve.set_defaults(func=command_serve)

    args = parser.parse_args()
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()

