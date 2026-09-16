#!/usr/bin/env python3
"""Run a deterministic vLLM context-ramp evaluation with GPU telemetry."""

import concurrent.futures
import csv
import json
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request


RUN_DIR = pathlib.Path(sys.argv[1]).resolve()
RUN_DIR.mkdir(parents=True, exist_ok=True)

STOP = threading.Event()
STATE_LOCK = threading.Lock()
STATE = {
    "phase": "starting",
    "next_phase": "missing",
    "cycle": 0,
    "phase_index": -1,
    "completed": 0,
    "success": 0,
    "errors": 0,
    "active_requests": 0,
    "peak_count": 0,
    "current_vram_mb": 0,
    "baseline_vram_mb": 0,
    "peak_vram_mb": 0,
    "peak_window_active": False,
    "peak_marked_this_phase": False,
}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def atomic_write_json(path, data):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def update_state(**items):
    with STATE_LOCK:
        STATE.update(items)
        snapshot = dict(STATE)
    atomic_write_json(RUN_DIR / "progress.json", snapshot)
    return snapshot


def sample_compute_apps():
    cmd = [
        "nvidia-smi",
        "--query-compute-apps=pid,process_name,used_memory,gpu_uuid",
        "--format=csv,noheader,nounits",
    ]
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=3)
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 4:
            continue
        try:
            rows.append({
                "pid": int(parts[0]),
                "process_name": parts[1],
                "used_memory_mb": int(parts[2]),
                "gpu_uuid": parts[3],
            })
        except ValueError:
            continue
    return rows


def telemetry_loop():
    telemetry_path = RUN_DIR / "telemetry.csv"
    with telemetry_path.open("a", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["timestamp", "phase", "cycle", "pid", "process_name", "used_memory_mb", "gpu_uuid"])
        fh.flush()
        while not STOP.is_set():
            rows = sample_compute_apps()
            with STATE_LOCK:
                phase = STATE["phase"]
                cycle = STATE["cycle"]
            max_mem = max([row["used_memory_mb"] for row in rows], default=0)
            for row in rows:
                writer.writerow([now(), phase, cycle, row["pid"], row["process_name"], row["used_memory_mb"], row["gpu_uuid"]])
            fh.flush()

            with STATE_LOCK:
                STATE["current_vram_mb"] = max_mem
                if phase.startswith("short_context") and max_mem:
                    prior = STATE.get("baseline_vram_mb", 0)
                    STATE["baseline_vram_mb"] = max(prior, max_mem)
                if phase == "long_context_peak":
                    STATE["peak_vram_mb"] = max(STATE.get("peak_vram_mb", 0), max_mem)
                    if max_mem >= int(os.environ["A_LONG_PEAK_VRAM_MB"]) and not STATE.get("peak_marked_this_phase"):
                        STATE["peak_marked_this_phase"] = True
                        STATE["peak_window_active"] = True
                        STATE["peak_count"] = int(STATE.get("peak_count", 0)) + 1
                        peak_doc = dict(STATE)
                        peak_doc["peak_observed_at"] = now()
                        peak_doc["telemetry_rows"] = rows
                        atomic_write_json(RUN_DIR / "peak_window.json", peak_doc)
                else:
                    STATE["peak_window_active"] = False
                snapshot = dict(STATE)
            atomic_write_json(RUN_DIR / "telemetry_summary.json", snapshot)
            atomic_write_json(RUN_DIR / "progress.json", snapshot)
            STOP.wait(float(os.environ.get("A_TELEMETRY_INTERVAL_SECONDS", "1.0")))


def wait_server_ready(port, server):
    url = f"http://127.0.0.1:{port}/v1/models"
    deadline = time.time() + int(os.environ.get("A_SERVER_READY_TIMEOUT_SECONDS", "900"))
    while time.time() < deadline:
        if server.poll() is not None:
            raise RuntimeError(f"vLLM exited before readiness rc={server.returncode}")
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                json.load(response)
            return
        except Exception:
            time.sleep(1)
    raise TimeoutError("vLLM readiness timed out")


def start_vllm():
    port = os.environ["A_PORT"]
    cmd = [
        os.environ["A_VLLM_PYTHON"],
        "-m",
        "vllm.entrypoints.openai.api_server",
        "--model",
        os.environ["A_MODEL_PATH"],
        "--host",
        "127.0.0.1",
        "--port",
        port,
        "--served-model-name",
        os.environ["A_SERVED_MODEL"],
        "--dtype",
        "bfloat16",
        "--max-model-len",
        os.environ["A_MAX_MODEL_LEN"],
        "--max-num-seqs",
        os.environ["A_MAX_NUM_SEQS"],
        "--max-num-batched-tokens",
        os.environ["A_MAX_NUM_BATCHED_TOKENS"],
        "--gpu-memory-utilization",
        os.environ["A_GPU_MEMORY_UTILIZATION"],
        "--trust-remote-code",
        "--enable-prefix-caching",
        "--reasoning-parser",
        "qwen3",
        "--language-model-only",
        "--gdn-prefill-backend",
        "triton",
    ]
    extra = os.environ.get("A_VLLM_EXTRA_ARGS", "").strip()
    if extra:
        cmd.extend(shlex.split(extra))
    with (RUN_DIR / "vllm.command.json").open("w") as fh:
        json.dump(cmd, fh, indent=2)
    log = (RUN_DIR / "vllm.log").open("ab")
    server = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    (RUN_DIR / "server.pid").write_text(f"{server.pid}\n")
    wait_server_ready(port, server)
    (RUN_DIR / "server_ready_at").write_text(now() + "\n")
    return server


def make_prompt(target_chars, phase, index):
    header = (
        f"Context ramp validation request {phase}-{index}. "
        "Summarize the invariant, identify two implementation risks, and keep the answer deterministic.\n"
    )
    unit = (
        "Module owns a local tool-calling trace with schema fields, tensor shapes, retry decisions, "
        "and checksum markers. Preserve ordering, compare counters, and reason about bounded GPU memory. "
    )
    body = header
    while len(body) < target_chars:
        body += unit
    return body[:target_chars]


def post_completion(port, model, payload):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=int(os.environ["A_REQUEST_TIMEOUT_SECONDS"])) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def run_one_request(phase, req_index, target_chars, max_tokens):
    port = os.environ["A_PORT"]
    model = os.environ["A_SERVED_MODEL"]
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": make_prompt(target_chars, phase, req_index)}],
        "temperature": 0,
        "max_tokens": max_tokens,
        "stream": False,
    }
    started = time.time()
    try:
        response = post_completion(port, model, payload)
        text = json.dumps({
            "timestamp": now(),
            "phase": phase,
            "request_index": req_index,
            "target_chars": target_chars,
            "max_tokens": max_tokens,
            "status": "ok",
            "elapsed_seconds": round(time.time() - started, 3),
            "response_id": response.get("id"),
            "finish_reason": (response.get("choices") or [{}])[0].get("finish_reason"),
            "output_chars": len(json.dumps(response)),
        }, sort_keys=True)
        return True, text
    except Exception as exc:
        text = json.dumps({
            "timestamp": now(),
            "phase": phase,
            "request_index": req_index,
            "target_chars": target_chars,
            "max_tokens": max_tokens,
            "status": "error",
            "elapsed_seconds": round(time.time() - started, 3),
            "error": repr(exc),
        }, sort_keys=True)
        return False, text


def run_phase(phase, next_phase, cycle, phase_index, spec):
    update_state(
        phase=phase,
        next_phase=next_phase,
        cycle=cycle,
        phase_index=phase_index,
        active_requests=0,
        peak_marked_this_phase=False,
        peak_window_active=False,
        phase_started_at=now(),
    )
    target_chars = int(spec["target_chars"])
    requests = int(spec["requests"])
    concurrency = int(spec["concurrency"])
    max_tokens = int(spec["max_tokens"])
    output_path = RUN_DIR / "responses.jsonl"
    active = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = []
        for idx in range(requests):
            if STOP.is_set():
                break
            futures.append(pool.submit(run_one_request, phase, idx, target_chars, max_tokens))
            active += 1
            update_state(active_requests=active)
        for future in concurrent.futures.as_completed(futures):
            ok, line = future.result()
            active -= 1
            with output_path.open("a") as fh:
                fh.write(line + "\n")
            with STATE_LOCK:
                STATE["completed"] = int(STATE.get("completed", 0)) + 1
                if ok:
                    STATE["success"] = int(STATE.get("success", 0)) + 1
                else:
                    STATE["errors"] = int(STATE.get("errors", 0)) + 1
                STATE["active_requests"] = active
                snapshot = dict(STATE)
            atomic_write_json(RUN_DIR / "progress.json", snapshot)
            if STOP.is_set():
                break
    update_state(active_requests=0, peak_window_active=False, phase_completed_at=now())


def install_signal_handlers(server_holder):
    def handler(signum, _frame):
        STOP.set()
        server = server_holder.get("server")
        if server and server.poll() is None:
            server.terminate()
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


def main():
    (RUN_DIR / "eval.pid").write_text(f"{os.getpid()}\n")
    schedule = json.loads(pathlib.Path(os.environ["A_CONTEXT_RAMP_SCHEDULE"]).read_text())
    server_holder = {}
    install_signal_handlers(server_holder)
    telemetry = threading.Thread(target=telemetry_loop, daemon=True)
    telemetry.start()
    server = start_vllm()
    server_holder["server"] = server
    update_state(phase="server_ready", server_pid=server.pid, server_ready_at=now())

    cycle = 0
    while not STOP.is_set():
        for index, spec in enumerate(schedule["phases"]):
          if STOP.is_set():
              break
          next_phase = schedule["phases"][(index + 1) % len(schedule["phases"])]["phase"]
          run_phase(spec["phase"], next_phase, cycle, index, spec)
        cycle += 1
    STOP.set()
    if server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=20)
        except subprocess.TimeoutExpired:
            server.kill()
    telemetry.join(timeout=5)
    update_state(phase="stopped", stopped_at=now())


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        update_state(phase="failed", error=repr(exc), failed_at=now())
        print(f"CONTEXT_RAMP_FAILED {exc!r}", file=sys.stderr)
        raise
