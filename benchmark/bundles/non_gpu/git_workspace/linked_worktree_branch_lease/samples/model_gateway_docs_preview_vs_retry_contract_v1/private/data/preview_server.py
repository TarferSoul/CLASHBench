#!/usr/bin/env python3
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import signal
import subprocess
import threading
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True)
parser.add_argument("--runtime", required=True)
parser.add_argument("--port", type=int, required=True)
args = parser.parse_args()
repo = pathlib.Path(args.repo)
runtime = pathlib.Path(args.runtime)
site = runtime / "site"
state_path = runtime / "state.json"
pid_path = runtime / "server.pid"
running = True
lock = threading.Lock()
state = {}

def stop(_signum, _frame):
    global running
    running = False

def git(*items):
    return subprocess.check_output(["git", "-C", str(repo), *items], text=True).strip()

def publish(payload):
    global state
    with lock:
        state = payload
        temp = state_path.with_suffix(".tmp")
        temp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        os.replace(temp, state_path)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            with lock:
                payload = dict(state)
            body = json.dumps(payload, sort_keys=True).encode() + b"\n"
            self.send_response(200 if payload.get("health_ok") else 503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        slug = urllib.parse.urlparse(self.path).path.lstrip("/") or "index.html"
        file_path = site / slug
        if not file_path.is_file() or not file_path.resolve().is_relative_to(site.resolve()):
            self.send_error(404)
            return
        body = file_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return

runtime.mkdir(parents=True, exist_ok=True)
site.mkdir(parents=True, exist_ok=True)
pid_path.write_text(f"{os.getpid()}\n")
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
server.timeout = 0.2
generation = 0
while running:
    head = git("rev-parse", "HEAD")
    tree = git("rev-parse", "HEAD^{tree}")
    index_tree = git("write-tree")
    build = subprocess.run(["python3", "tools/build_docs.py", "--output", str(site)], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    render = site / "rate-limits.html"
    generation += 1
    health = build.returncode == 0 and tree == index_tree and render.is_file() and not git("status", "--porcelain")
    payload = {
        "pid": os.getpid(), "generation": generation, "health_ok": health,
        "head_oid": head, "head_tree": tree, "index_tree": index_tree,
        "render_sha256": hashlib.sha256(render.read_bytes()).hexdigest() if render.is_file() else "",
        "build_rc": build.returncode, "preview_port": args.port,
    }
    publish(payload)
    server.handle_request()
    if not health:
        break
pid_path.unlink(missing_ok=True)
server.server_close()
