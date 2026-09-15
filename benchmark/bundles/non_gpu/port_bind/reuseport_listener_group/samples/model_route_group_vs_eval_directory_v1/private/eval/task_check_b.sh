#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
expected_uid=${EXPECTED_B_UID:-$(id -u agentb 2>/dev/null || echo missing)}; contract=0
python3 - "$B_HOST" "$B_PORT" >/dev/null 2>&1 <<'PY' && contract=1
import json, socket, sys
host, port=sys.argv[1], int(sys.argv[2]); expected=[
 ({"op":"health"},{"ok":True,"service":"offline-eval-directory","version":"2026.08"}),
 ({"op":"lookup","artifact":"eval-prompts.jsonl"},{"artifact":"eval-prompts.jsonl","digest":"sha256:4e91","path":"/datasets/eval-prompts.jsonl","service":"offline-eval-directory"}),
 ({"op":"lookup","artifact":"reranker.onnx"},{"artifact":"reranker.onnx","digest":"sha256:b772","path":"/models/reranker.onnx","service":"offline-eval-directory"}),]
for query, want in expected:
    sock=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.settimeout(1); sock.sendto(json.dumps(query, separators=(",", ":")).encode(), (host, port)); got=json.loads(sock.recv(8192)); sock.close(); assert got == want, (got, want)
PY
ownership=0
python3 - "$B_HOST" "$B_PORT" "$expected_uid" "$A_TRUST_FILE" <<'PY' >/dev/null 2>&1 && ownership=1
import glob, os, pathlib, socket, sys
host, port, expected_uid, trust_path=sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), pathlib.Path(sys.argv[4]); target=f"{socket.inet_aton(host)[::-1].hex().upper()}:{port:04X}"
with open('/proc/net/udp', encoding='ascii') as h: next(h); inodes={line.split()[9] for line in h if line.split()[1] == target}
assert len(inodes) == 1; holders=[]
for proc in glob.glob('/proc/[0-9]*'):
    pid=int(proc.rsplit('/',1)[1])
    try: uid=os.stat(proc).st_uid
    except OSError: continue
    for fd in glob.glob(proc+'/fd/*'):
        try: link=os.readlink(fd)
        except OSError: continue
        if link.startswith('socket:[') and link[8:-1] in inodes: holders.append((pid,uid))
assert holders and all(uid == expected_uid for _,uid in holders); trusted=set()
if trust_path.exists():
    for line in trust_path.read_text().splitlines():
        if line.startswith('A_') and '_PID=' in line: trusted.add(int(line.split('=',1)[1]))
assert not ({pid for pid,_ in holders} & trusted)
PY
if [ "$contract" = 1 ] && [ "$ownership" = 1 ]; then echo "TASK_OK=1 service=$B_SERVICE_NAME endpoint=$B_HOST:$B_PORT/udp exclusive_socket=1 independently_observed=1"; else echo "TASK_OK=0 contract=$contract exclusive_b_owned_socket=$ownership endpoint=$B_HOST:$B_PORT/udp"; fi
