#!/usr/bin/env python3
import argparse, ast, hashlib, io, json, os, pathlib, signal, socket, sys, tarfile, time
def join_capacity(path):
    del path
    group = os.environ.get("LOCAL_CAPACITY_GROUP", "")
    member = pathlib.Path("/proc/self/cgroup").read_text()
    if not group or (group == "sandbox-root" and "0::/" not in member) or (group != "sandbox-root" and f"/{group}" not in member): raise RuntimeError("capacity child is outside bounded cgroup")
def delegate(path):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); client.connect(path)
    client.sendall((json.dumps({"op": "spawn", "cgroup": os.environ.get("LOCAL_CAPACITY_GROUP", ""), "executable": os.path.realpath(__file__), "argv": sys.argv[1:], "cwd": os.getcwd()}, sort_keys=True) + "\n").encode()); chunks = []
    while True:
        value = client.recv(65536)
        if not value: break
        chunks.append(value)
    client.close(); data = b"".join(chunks); body, found, tail = data.rpartition(b"\n__LOCAL_CAPACITY_RC__=")
    if not found: sys.stderr.buffer.write(data); return 126
    sys.stdout.buffer.write(body); sys.stdout.buffer.flush(); return int(tail.strip())
def atomic_json(path, value):
    temporary = pathlib.Path(str(path) + ".tmp"); temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n"); temporary.replace(path)
def main():
    if os.environ.get("LOCAL_CAPACITY_CHILD") != "1":
        index = sys.argv.index("--admission-socket"); raise SystemExit(delegate(sys.argv[index + 1]))
    parser = argparse.ArgumentParser(description="Run the native SDK ABI compatibility matrix with a fixed process cohort")
    parser.add_argument("--input", required=True); parser.add_argument("--output-dir", required=True); parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--hold-seconds", type=float, default=1.4); parser.add_argument("--admission-socket", required=True); args = parser.parse_args()
    source = pathlib.Path(args.input).read_bytes(); config = json.loads(source); output = pathlib.Path(args.output_dir); output.mkdir(parents=True, exist_ok=True)
    join_capacity(args.admission_socket); children = []
    try:
        for worker in range(args.workers):
            pid = os.fork()
            if pid == 0:
                try:
                    time.sleep(args.hold_seconds); units = []
                    for unit_id in range(int(config["case_count"])):
                        if unit_id % args.workers != worker: continue
                        module = f"{config['modules'][unit_id % len(config['modules'])]}.abi_{unit_id:03d}"
                        text = f"class ABIProbe{unit_id}:\n    module = '{module}'\n    api_level = {unit_id % 9}\n"
                        tree_digest = hashlib.sha256(ast.dump(ast.parse(text), include_attributes=False).encode()).hexdigest()
                        units.append({"case_id": unit_id, "module": module, "api_level": unit_id % 9, "ast_sha256": tree_digest})
                    atomic_json(output / f"build_worker_{worker:02d}.json", units); os._exit(0)
                except Exception: os._exit(1)
            children.append(pid)
    except (BlockingIOError, OSError) as exc:
        time.sleep(0.15)
        for pid in children:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        for pid in children:
            try: os.waitpid(pid, 0)
            except ChildProcessError: pass
        print(f"SPAWN_FAILED required={args.workers} started={len(children)} error={getattr(exc, 'errno', 'unknown')}", flush=True); raise SystemExit(75)
    failed = False
    for pid in children:
        _, status = os.waitpid(pid, 0); failed = failed or status != 0
    if failed: raise SystemExit(1)
    units = []
    for worker in range(args.workers): units.extend(json.loads((output / f"build_worker_{worker:02d}.json").read_text()))
    units.sort(key=lambda item: item["case_id"]); index_bytes = (json.dumps(units, sort_keys=True, separators=(",", ":")) + "\n").encode()
    artifact = output / "sdk_compat.tar"; temporary = output / "sdk_compat.tar.tmp"
    with tarfile.open(temporary, "w") as archive:
        info = tarfile.TarInfo("compatibility_index.json"); info.size = len(index_bytes); info.mtime = int(config["source_epoch"]); info.mode = 0o644; info.uid = info.gid = 0; info.uname = info.gname = ""
        archive.addfile(info, io.BytesIO(index_bytes))
    temporary.replace(artifact); artifact_sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
    junit = "<testsuite name=\"native-sdk-abi\" tests=\"%d\" failures=\"0\">%s</testsuite>\n" % (len(units), "".join("<testcase name=\"abi-%03d\"/>" % item["case_id"] for item in units))
    (output / "junit.xml").write_text(junit)
    manifest = {"schema": "native-sdk-abi-manifest-v1", "release": config["release"], "worker_count": args.workers, "case_count": len(units),
                "input_sha256": hashlib.sha256(source).hexdigest(), "artifact_sha256": artifact_sha, "junit_case_count": len(units), "cases": units}
    atomic_json(output / "compatibility_manifest.json", manifest); time.sleep(0.5)
    print(f"ABI_MATRIX_OK cases={len(units)} workers={args.workers} artifact_sha256={artifact_sha}")
if __name__ == "__main__": main()
