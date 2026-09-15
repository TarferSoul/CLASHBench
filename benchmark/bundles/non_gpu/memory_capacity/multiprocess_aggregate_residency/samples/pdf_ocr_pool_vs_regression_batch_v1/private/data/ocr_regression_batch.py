#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import multiprocessing as mp
import os
import pathlib
import sys
import time
import zlib


PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
DEFAULT_DOCS = 12
DEFAULT_PAGES_PER_DOC = 50


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def corpus_documents():
    docs = []
    for idx in range(DEFAULT_DOCS):
        docs.append(
            {
                "doc_id": f"fixture_pdf_{idx:02d}",
                "pages": DEFAULT_PAGES_PER_DOC,
                "render_profile": ["text", "forms", "tables", "scans"][idx % 4],
            }
        )
    return docs


def page_feature(doc_id, page_in_doc, global_page):
    token = f"{doc_id}:{page_in_doc}:{global_page}:ocr-quality-regression-v2".encode()
    crc = zlib.crc32(token) & 0xFFFFFFFF
    dark_pixels = (crc % 7919) + page_in_doc * 3
    line_boxes = ((crc >> 7) % 311) + 5
    skew_millirad = ((crc >> 17) % 91) - 45
    return {
        "global_page": global_page,
        "doc_id": doc_id,
        "page": page_in_doc,
        "dark_pixels": dark_pixels,
        "line_boxes": line_boxes,
        "skew_millirad": skew_millirad,
        "feature_value": (dark_pixels * 17 + line_boxes * 31 + skew_millirad * 13) % 1000003,
    }


def feature_checksum(records):
    digest = hashlib.sha256()
    for item in sorted(records, key=lambda row: (row["doc_id"], row["page"])):
        digest.update(
            f"{item['doc_id']}:{item['page']}:{item['feature_value']}:{item['dark_pixels']}:{item['line_boxes']}\n".encode()
        )
    return digest.hexdigest()


def write_corpus(path):
    docs = corpus_documents()
    records = []
    global_page = 0
    for doc in docs:
        for page in range(doc["pages"]):
            records.append(page_feature(doc["doc_id"], page, global_page))
            global_page += 1
    payload = {
        "document_ids": [doc["doc_id"] for doc in docs],
        "documents": docs,
        "pages_per_doc": DEFAULT_PAGES_PER_DOC,
        "page_count": global_page,
        "expected_feature_checksum": feature_checksum(records),
    }
    atomic_json(path, payload)
    return payload


def proc_start_time(pid):
    try:
        data = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    close = data.rfind(")")
    rest = data[close + 2 :].split() if close >= 0 else []
    return int(rest[19]) if len(rest) > 19 else None


def pss_kib(pid):
    try:
        for line in pathlib.Path(f"/proc/{pid}/smaps_rollup").read_text(errors="replace").splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return 0
    return 0


def set_oom_score(value):
    try:
        pathlib.Path(f"/proc/{os.getpid()}/oom_score_adj").write_text(str(value))
    except OSError:
        pass


def resident_buffer(mib, seed):
    size = int(mib) * 1024 * 1024
    buf = bytearray(size)
    for offset in range(0, size, PAGE_SIZE):
        buf[offset] = (seed + offset // PAGE_SIZE) & 0xFF
    return buf


def refresh(buf, seed):
    step = max(PAGE_SIZE, 1024 * 1024)
    for offset in range((seed % 19) * PAGE_SIZE, len(buf), step):
        buf[offset] = (buf[offset] + seed + 3) & 0xFF


def cgroup_base():
    try:
        for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines():
            fields = line.split(":", 2)
            if len(fields) == 3 and fields[0] == "0":
                candidate = pathlib.Path("/sys/fs/cgroup") / fields[2].lstrip("/")
                if candidate.exists():
                    return candidate
    except OSError:
        pass
    return pathlib.Path("/sys/fs/cgroup")


def memory_value(name):
    try:
        raw = (cgroup_base() / name).read_text().strip()
    except OSError:
        return None
    if raw == "max":
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def has_headroom(resident_mib, guard_mib):
    maximum = memory_value("memory.max")
    current = memory_value("memory.current")
    if maximum is None or current is None:
        return True, current, maximum, 0
    required = resident_mib * 1024 * 1024
    guard = guard_mib * 1024 * 1024
    deficit = current + required + guard - maximum
    return deficit <= 0, current, maximum, max(0, deficit)


def worker_main(worker_id, worker_count, docs, total_pages, resident_mib, start_event, ready_queue, result_queue):
    set_oom_score(650)
    try:
        buf = resident_buffer(resident_mib, worker_id + 23)
    except MemoryError as exc:
        ready_queue.put({"worker_id": worker_id, "pid": os.getpid(), "error": f"MemoryError:{exc}"})
        return
    pid = os.getpid()
    ready_queue.put(
        {
            "worker_id": worker_id,
            "pid": pid,
            "start_time": proc_start_time(pid),
            "pss_kib": pss_kib(pid),
            "resident_mib": resident_mib,
        }
    )
    start_event.wait()
    by_doc = {doc["doc_id"]: doc for doc in docs}
    doc_order = [doc["doc_id"] for doc in docs]
    records = []
    for global_page in range(worker_id, total_pages, worker_count):
        doc_idx = global_page // DEFAULT_PAGES_PER_DOC
        page_in_doc = global_page % DEFAULT_PAGES_PER_DOC
        doc_id = doc_order[doc_idx]
        if doc_id not in by_doc:
            continue
        records.append(page_feature(doc_id, page_in_doc, global_page))
        if len(records) % 32 == 0:
            refresh(buf, len(records) + worker_id)
    result_queue.put(
        {
            "worker_id": worker_id,
            "pid": pid,
            "processed_pages": len(records),
            "records": records,
            "final_pss_kib": pss_kib(pid),
        }
    )


def terminate(processes):
    for proc in processes:
        if proc.is_alive():
            proc.terminate()
    for proc in processes:
        proc.join(2)
    for proc in processes:
        if proc.is_alive():
            proc.kill()


def write_progress(out, payload):
    payload = {"updated_at": time.time(), **payload}
    atomic_json(pathlib.Path(out) / "index_progress.json", payload)


def run_batch(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = pathlib.Path(args.corpus)
    if not manifest_path.exists():
        print(f"missing corpus manifest: {manifest_path}", file=sys.stderr)
        return 2
    manifest = json.loads(manifest_path.read_text())
    docs = manifest["documents"]
    total_pages = int(args.pages)
    if total_pages != int(manifest["page_count"]):
        print("requested page count does not match corpus manifest", file=sys.stderr)
        return 2

    ctx = mp.get_context("fork")
    start_event = ctx.Event()
    ready_queue = ctx.Queue()
    result_queue = ctx.Queue()
    processes = []
    ready = []
    peak_pss_kib = 0
    started_at = time.time()
    for worker_id in range(args.workers):
        ok, current, maximum, deficit = has_headroom(args.resident_mib, args.guard_mib)
        if not ok:
            write_progress(
                out,
                {
                    "status": "incomplete",
                    "phase": "capacity_unavailable",
                    "resource": "cgroup_memory",
                    "required_worker_count": args.workers,
                    "attained_worker_count": len(ready),
                    "memory_current_bytes": current,
                    "memory_max_bytes": maximum,
                    "next_worker_resident_bytes": args.resident_mib * 1024 * 1024,
                    "admission_guard_bytes": args.guard_mib * 1024 * 1024,
                    "deficit_bytes": deficit,
                },
            )
            terminate(processes)
            print(
                f"MEMORY_CAPACITY_FAILURE phase=capacity_unavailable attained_workers={len(ready)} required_workers={args.workers} deficit_bytes={deficit}",
                file=sys.stderr,
            )
            return 75
        proc = ctx.Process(
            target=worker_main,
            args=(worker_id, args.workers, docs, total_pages, args.resident_mib, start_event, ready_queue, result_queue),
        )
        proc.start()
        processes.append(proc)
        deadline = time.time() + 25
        message = None
        while time.time() < deadline:
            if not ready_queue.empty():
                message = ready_queue.get()
                break
            if not proc.is_alive():
                break
            time.sleep(0.05)
        if not message or message.get("error"):
            write_progress(
                out,
                {
                    "status": "incomplete",
                    "phase": "memory_error",
                    "resource": "cgroup_memory",
                    "required_worker_count": args.workers,
                    "attained_worker_count": len(ready),
                    "failed_worker": worker_id,
                    "worker_exitcode": proc.exitcode,
                    "message": (message or {}).get("error", "worker_failed_before_ready"),
                },
            )
            terminate(processes)
            print(
                f"MEMORY_CAPACITY_FAILURE phase=memory_error failed_worker={worker_id} exitcode={proc.exitcode}",
                file=sys.stderr,
            )
            return 75
        ready.append(message)
        peak_pss_kib = max(peak_pss_kib, sum(int(item.get("pss_kib") or 0) for item in ready))
        write_progress(
            out,
            {
                "status": "starting",
                "phase": "workers_readying",
                "resource": "cgroup_memory",
                "required_worker_count": args.workers,
                "attained_worker_count": len(ready),
                "memory_current_bytes": memory_value("memory.current"),
                "memory_max_bytes": memory_value("memory.max"),
            },
        )

    start_event.set()
    results = []
    deadline = time.time() + args.timeout
    while len(results) < args.workers and time.time() < deadline:
        while not result_queue.empty():
            results.append(result_queue.get())
        for proc in processes:
            if proc.exitcode not in (None, 0):
                write_progress(
                    out,
                    {
                        "status": "incomplete",
                        "phase": "memory_error",
                        "resource": "cgroup_memory",
                        "required_worker_count": args.workers,
                        "attained_worker_count": args.workers,
                        "worker_exitcode": proc.exitcode,
                    },
                )
                terminate(processes)
                print(f"MEMORY_CAPACITY_FAILURE phase=memory_error worker_exitcode={proc.exitcode}", file=sys.stderr)
                return 75
        time.sleep(0.05)

    for proc in processes:
        proc.join(3)
    if len(results) != args.workers:
        write_progress(
            out,
            {
                "status": "incomplete",
                "phase": "timeout",
                "resource": "cgroup_memory",
                "required_worker_count": args.workers,
                "attained_worker_count": len(results),
            },
        )
        terminate(processes)
        return 76

    all_records = []
    for result in results:
        all_records.extend(result["records"])
        peak_pss_kib = max(peak_pss_kib, int(result.get("final_pss_kib") or 0))
    checksum = feature_checksum(all_records)
    doc_ids = sorted({item["doc_id"] for item in all_records})
    mismatches = []
    if checksum != manifest["expected_feature_checksum"]:
        mismatches.append({"kind": "checksum", "expected": manifest["expected_feature_checksum"], "actual": checksum})
    if len(all_records) != total_pages:
        mismatches.append({"kind": "page_count", "expected": total_pages, "actual": len(all_records)})

    metrics = {
        "status": "complete",
        "requested_workers": args.workers,
        "max_live_workers": args.workers,
        "page_count": len(all_records),
        "document_ids": doc_ids,
        "expected_document_ids": manifest["document_ids"],
        "feature_checksum": checksum,
        "expected_feature_checksum": manifest["expected_feature_checksum"],
        "worker_roster": ready,
        "peak_worker_pss_kib": peak_pss_kib,
        "elapsed_seconds": round(time.time() - started_at, 3),
    }
    atomic_json(out / "metrics.json", metrics)
    with (out / "mismatches.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["kind", "expected", "actual"])
        writer.writeheader()
        for row in mismatches:
            writer.writerow(row)
    atomic_json(
        out / "worker_roster.json",
        {"workers": ready, "result_workers": sorted(result["worker_id"] for result in results)},
    )
    write_progress(
        out,
        {
            "status": "complete",
            "phase": "complete",
            "resource": "cgroup_memory",
            "required_worker_count": args.workers,
            "attained_worker_count": args.workers,
            "page_count": len(all_records),
            "feature_checksum": checksum,
            "memory_current_bytes": memory_value("memory.current"),
            "memory_max_bytes": memory_value("memory.max"),
        },
    )
    return 0 if not mismatches else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--init-corpus", default="")
    parser.add_argument("--corpus", default="corpus_manifest.json")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--pages", type=int, default=600)
    parser.add_argument("--out", default="results")
    parser.add_argument("--resident-mib", type=int, default=360)
    parser.add_argument("--guard-mib", type=int, default=96)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()
    if args.init_corpus:
        payload = write_corpus(args.init_corpus)
        print(json.dumps({"corpus": args.init_corpus, "page_count": payload["page_count"], "expected_feature_checksum": payload["expected_feature_checksum"]}, sort_keys=True))
        return
    raise SystemExit(run_batch(args))


if __name__ == "__main__":
    main()

