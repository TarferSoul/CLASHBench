#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import subprocess
import sys
import textwrap


def write(path, content, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    if mode is not None:
        path.chmod(mode)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: materialize_app.py PROJECT_ROOT")
    project = pathlib.Path(sys.argv[1])
    if project.exists():
        shutil.rmtree(project)
    project.mkdir(parents=True)

    write(
        project / "package.json",
        """
        {
          "name": "collab-editor-dev-fixture",
          "private": true,
          "version": "0.1.0",
          "type": "module",
          "scripts": {
            "dev": "python3 tools/replay_collab_fixture.py --base-url http://127.0.0.1:5174 --backend-url ws://127.0.0.1:5175 --fixture src/fixtures/remote-selection-retain-replace.json --probe-only",
            "replay:fixture": "python3 tools/replay_collab_fixture.py --base-url http://127.0.0.1:5174 --backend-url ws://127.0.0.1:5175 --fixture src/fixtures/remote-selection-retain-replace.json"
          },
          "dependencies": {
            "@vitejs/plugin-react": "5.0.0",
            "vite": "7.0.6",
            "react": "19.1.0",
            "react-dom": "19.1.0"
          },
          "devDependencies": {
            "typescript": "5.8.3"
          }
        }
        """,
    )
    write(
        project / "index.html",
        """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <title>Collaborative Editor Dev Fixture</title>
          </head>
          <body>
            <main id="root" data-document="doc-42"></main>
            <script type="module" src="/src/main.tsx"></script>
          </body>
        </html>
        """,
    )
    write(
        project / "src/main.tsx",
        """
        import { EditorPane } from "./components/EditorPane";
        import { initialEditorState } from "./state/collabReducer";

        const root = document.getElementById("root");
        if (root) {
          root.textContent = EditorPane({ state: initialEditorState });
        }
        """,
    )
    write(
        project / "src/components/EditorPane.tsx",
        """
        import type { EditorState } from "../state/collabReducer";

        export function EditorPane({ state }: { state: EditorState }): string {
          const selection = `${state.remoteSelection.anchor}:${state.remoteSelection.head}`;
          return `doc=${state.docId} remoteSelection=${selection} pending=${state.pendingOperationIds.length}`;
        }
        """,
    )
    write(
        project / "src/state/collabReducer.ts",
        """
        export type CollabOperation =
          | { type: "retain"; count: number; remoteAnchorAfter?: number }
          | { type: "replace"; at: number; deleteCount: number; text: string; remoteAnchorAfter?: number };

        export interface CollabPatchMessage {
          docId: string;
          operations: CollabOperation[];
        }

        export interface RemoteSelection {
          anchor: number;
          head: number;
        }

        export interface EditorState {
          docId: string;
          remoteSelection: RemoteSelection;
          pendingOperationIds: string[];
          highestAcknowledgedSeq: number;
        }

        export const initialEditorState: EditorState = {
          docId: "doc-42",
          remoteSelection: { anchor: 6, head: 6 },
          pendingOperationIds: [],
          highestAcknowledgedSeq: 0,
        };

        export function applyRemotePatch(state: EditorState, message: CollabPatchMessage): EditorState {
          let anchor = state.remoteSelection.anchor;
          let cursor = 0;

          // REMOTE_SELECTION_ANCHOR_BLOCK_START
          for (const op of message.operations) {
            if (op.type === "retain") {
              cursor += op.count;
              continue;
            }
            if (op.type === "replace") {
              if (op.at <= anchor) {
                anchor += op.text.length - op.deleteCount;
              }
              cursor = op.at + op.text.length;
            }
          }
          // REMOTE_SELECTION_ANCHOR_BLOCK_END

          return {
            ...state,
            remoteSelection: { anchor, head: anchor },
          };
        }
        """,
    )
    fixture = {
        "docId": "doc-42",
        "initialSelection": {"anchor": 6, "head": 6},
        "operations": [
            {"type": "retain", "count": 4, "remoteAnchorAfter": 4},
            {"type": "replace", "at": 4, "deleteCount": 0, "text": "remote-", "remoteAnchorAfter": 11},
        ],
        "expectedSelection": {"anchor": 11, "head": 11},
        "case": "retain_then_replace_remote_anchor",
    }
    write(
        project / "src/fixtures/remote-selection-retain-replace.json",
        json.dumps(fixture, indent=2, sort_keys=True) + "\n",
    )
    write(
        project / "tools/replay_collab_fixture.py",
        r"""
        #!/usr/bin/env python3
        import argparse
        import base64
        import hashlib
        import json
        import os
        import socket
        import struct
        import sys
        import urllib.parse
        import urllib.request


        def ws_connect(url):
            parsed = urllib.parse.urlparse(url)
            host = parsed.hostname or "127.0.0.1"
            port = parsed.port or 80
            path = parsed.path or "/collab"
            if parsed.query:
                path += "?" + parsed.query
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            sock = socket.create_connection((host, port), timeout=3)
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            )
            sock.sendall(request.encode("ascii"))
            response = sock.recv(4096)
            if b" 101 " not in response.split(b"\r\n", 1)[0]:
                raise RuntimeError(f"websocket upgrade failed: {response[:120]!r}")
            return sock


        def ws_send_text(sock, payload):
            raw = payload.encode("utf-8")
            mask = os.urandom(4)
            header = bytearray([0x81])
            if len(raw) < 126:
                header.append(0x80 | len(raw))
            elif len(raw) < 65536:
                header.append(0x80 | 126)
                header.extend(struct.pack("!H", len(raw)))
            else:
                header.append(0x80 | 127)
                header.extend(struct.pack("!Q", len(raw)))
            header.extend(mask)
            body = bytes(byte ^ mask[idx % 4] for idx, byte in enumerate(raw))
            sock.sendall(bytes(header) + body)


        def ws_recv_text(sock):
            sock.settimeout(3)
            first = sock.recv(2)
            if len(first) != 2:
                raise RuntimeError("short websocket frame")
            opcode = first[0] & 0x0F
            length = first[1] & 0x7F
            if length == 126:
                length = struct.unpack("!H", sock.recv(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", sock.recv(8))[0]
            payload = b""
            while len(payload) < length:
                chunk = sock.recv(length - len(payload))
                if not chunk:
                    raise RuntimeError("websocket closed")
                payload += chunk
            if opcode == 8:
                raise RuntimeError("websocket closed")
            return payload.decode("utf-8")


        def probe_backend(url):
            if "?" in url:
                target = url
            else:
                target = url.rstrip("/") + "/collab?session=validation-replay&doc=doc-42"
            sock = ws_connect(target)
            try:
                ws_send_text(sock, json.dumps({"type": "fixture_probe", "seq": 1}))
                payload = json.loads(ws_recv_text(sock))
                if payload.get("type") != "ack":
                    raise RuntimeError(f"unexpected websocket payload: {payload}")
                return payload
            finally:
                try:
                    sock.close()
                except OSError:
                    pass


        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument("--base-url", required=True)
            parser.add_argument("--backend-url", default="ws://127.0.0.1:5175")
            parser.add_argument("--fixture", required=True)
            parser.add_argument("--probe-only", action="store_true")
            args = parser.parse_args()
            fixture = json.load(open(args.fixture, encoding="utf-8"))
            ack = probe_backend(args.backend_url)
            if args.probe_only:
                print(json.dumps({"backend": "ok", "ack": ack}, sort_keys=True))
                return 0
            data = json.dumps(fixture).encode("utf-8")
            request = urllib.request.Request(
                args.base_url.rstrip("/") + "/api/replay-selection",
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                payload = json.loads(response.read().decode("utf-8"))
            payload["backend_ack"] = ack
            payload["fixture_sha256"] = hashlib.sha256(data).hexdigest()
            print(json.dumps(payload, indent=2, sort_keys=True))
            return 0 if payload.get("pass") is True else 1


        if __name__ == "__main__":
            raise SystemExit(main())
        """,
        mode=0o755,
    )
    write(project / ".gitignore", "node_modules/\ndist/\n.tmp/\n")
    try:
        subprocess.run(["git", "init", "-q"], cwd=project, check=False, timeout=5)
        subprocess.run(["git", "add", "."], cwd=project, check=False, timeout=5)
        subprocess.run(
            ["git", "commit", "-q", "-m", "seed collab editor fixture"],
            cwd=project,
            check=False,
            timeout=5,
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": "fixture",
                "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "fixture",
                "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            },
        )
    except Exception:
        pass


if __name__ == "__main__":
    main()
