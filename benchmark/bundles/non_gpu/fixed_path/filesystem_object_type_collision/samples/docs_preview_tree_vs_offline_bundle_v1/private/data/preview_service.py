#!/usr/bin/env python3
import http.server
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def send_json(self, code, value):
        body = json.dumps(value, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/health":
            manifest = root / "release.json"
            index = root / "index.html"
            if not root.is_dir() or not manifest.is_file() or not index.is_file():
                self.send_json(503, {"status": "unready", "reason": "preview_tree_missing"})
                return
            try:
                release = json.loads(manifest.read_text())
            except Exception:
                self.send_json(503, {"status": "unready", "reason": "manifest_invalid"})
                return
            if release.get("release") != "docs-preview-2026-08":
                self.send_json(503, {"status": "unready", "reason": "release_changed"})
                return
            self.send_json(200, {"status": "ready", "release": release["release"], "asset": "index.html"})
            return
        if self.path == "/asset/app.js":
            asset = root / "assets/app.js"
            if root.is_dir() and asset.is_file():
                body = asset.read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        self.send_error(404)

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
