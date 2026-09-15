#!/usr/bin/env python3
"""Enter a two-UID user/mount namespace, preserving root and agentb."""
import ctypes
import errno
import os
import signal
import sys

CLONE_NEWNS = 0x00020000
CLONE_NEWUSER = 0x10000000
libc = ctypes.CDLL(None, use_errno=True)


def write(path, value):
    with open(path, "w", encoding="ascii") as stream:
        stream.write(value)


def main():
    if len(sys.argv) < 5:
        raise SystemExit("usage: userns_exec.py AGENT_UID AGENT_GID COMMAND...")
    agent_uid = int(sys.argv[1])
    agent_gid = int(sys.argv[2])
    command = sys.argv[3:]
    ready_r, ready_w = os.pipe()
    go_r, go_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_r)
        os.close(go_w)
        if libc.unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0:
            error = ctypes.get_errno()
            os.write(ready_w, f"E{error}".encode("ascii"))
            os._exit(125)
        os.write(ready_w, b"R")
        os.close(ready_w)
        if os.read(go_r, 1) != b"G":
            os._exit(126)
        os.close(go_r)
        os.setgid(0)
        os.setuid(0)
        os.execvpe(command[0], command, os.environ)

    os.close(ready_w)
    os.close(go_r)
    status = os.read(ready_r, 32)
    os.close(ready_r)
    if status != b"R":
        os.close(go_w)
        os.waitpid(pid, 0)
        code = int(status[1:] or errno.EPERM) if status.startswith(b"E") else errno.EPERM
        raise OSError(code, "unshare(CLONE_NEWUSER|CLONE_NEWNS) failed")
    proc = f"/proc/{pid}"
    try:
        write(f"{proc}/setgroups", "deny\n")
        write(f"{proc}/uid_map", f"0 0 1\n{agent_uid} {agent_uid} 1\n")
        write(f"{proc}/gid_map", f"0 0 1\n{agent_gid} {agent_gid} 1\n")
    except Exception:
        os.close(go_w)
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise

    def forward(signum, _frame):
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    os.write(go_w, b"G")
    os.close(go_w)
    _, wait_status = os.waitpid(pid, 0)
    if os.WIFEXITED(wait_status):
        raise SystemExit(os.WEXITSTATUS(wait_status))
    raise SystemExit(128 + os.WTERMSIG(wait_status))


if __name__ == "__main__":
    main()
