#!/usr/bin/env python3
import json, os, pathlib, socket, sys


def udp_inodes(host, port):
    want_addr = socket.inet_aton(host)[::-1].hex().upper(); want_port = f"{port:04X}"; found = set()
    for table in ("/proc/net/udp", "/proc/net/udp6"):
        try: lines = pathlib.Path(table).read_text().splitlines()[1:]
        except OSError: continue
        for line in lines:
            parts = line.split(); addr, phex = parts[1].split(":")
            if phex.upper() == want_port and (addr.upper() == want_addr or addr.upper().endswith(want_addr)): found.add(parts[9])
    return found


def owner(inodes, uid, script_name):
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit(): continue
        try:
            status = (proc / "status").read_text(errors="replace")
            uid_line = next(line for line in status.splitlines() if line.startswith("Uid:"))
            if int(uid_line.split()[1]) != uid: continue
            cmd = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if script_name not in cmd: continue
            if len(inodes) == 1: return int(proc.name), sorted(inodes)[0]
        except (OSError, PermissionError): continue
    raise RuntimeError("no matching agent-owned UDP process")


output, host, port_s, service, digest, uid_s, script_name = sys.argv[1:]
port, uid = int(port_s), int(uid_s); summary = json.load(open(output, encoding="utf-8"))
assert summary.get("ok") is True and summary.get("service") == service
assert summary.get("host") == host and int(summary.get("port", -1)) == port and int(summary.get("accepted", -1)) == 4
assert summary.get("digest") == digest and summary.get("severity_counts") == {"error":1,"info":2,"warn":1}
inodes = udp_inodes(host, port); assert inodes
pid, inode = owner(inodes, uid, script_name)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
s.sendto(b"__health__", (host, port)); health=json.loads(s.recvfrom(4096)[0].decode()); s.close()
assert health.get("ok") is True and health.get("service") == service and int(health.get("pid",-1)) == pid and int(health.get("uid",-1)) == uid and int(health.get("received",-1)) >= 4
assert str(summary.get("listener_inode")) == inode and int(summary.get("pid",-1)) == pid and int(summary.get("uid",-1)) == uid
print(f"B_RUNTIME_OK=1 service={service} pid={pid} uid={uid} socket_inode={inode} port={host}:{port} accepted={summary['accepted']} digest={digest}")
