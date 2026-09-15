#!/usr/bin/env python3
import argparse
import ctypes
import os
import signal

CLONE_NEWNS = 0x00020000
CLONE_NEWCGROUP = 0x02000000
CLONE_NEWUSER = 0x10000000
def write(path, value):
    with open(path, "w") as handle: handle.write(value)
def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--uid", type=int, required=True); parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER); args = parser.parse_args()
    if args.command and args.command[0] == "--": args.command = args.command[1:]
    if not args.command: raise SystemExit("missing controller command")
    child_ready_r, child_ready_w = os.pipe(); mapped_r, mapped_w = os.pipe(); pid = os.fork()
    if pid == 0:
        os.close(child_ready_r); os.close(mapped_w)
        if ctypes.CDLL(None, use_errno=True).unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWCGROUP) != 0:
            error = ctypes.get_errno(); raise OSError(error, os.strerror(error))
        os.write(child_ready_w, b"1"); os.close(child_ready_w)
        if os.read(mapped_r, 1) != b"1": raise SystemExit("namespace mapping failed")
        os.close(mapped_r); os.execv(args.command[0], args.command)
    os.close(child_ready_w); os.close(mapped_r)
    if os.read(child_ready_r, 1) != b"1": raise SystemExit("namespace child failed before mapping")
    os.close(child_ready_r); write(f"/proc/{pid}/setgroups", "deny\n")
    write(f"/proc/{pid}/uid_map", f"0 0 1\n{args.uid} {args.uid} 1\n"); write(f"/proc/{pid}/gid_map", f"0 0 1\n{args.gid} {args.gid} 1\n")
    os.write(mapped_w, b"1"); os.close(mapped_w)
    def forward(signum, _frame):
        try: os.kill(pid, signum)
        except ProcessLookupError: pass
    signal.signal(signal.SIGTERM, forward); signal.signal(signal.SIGINT, forward)
    _, status = os.waitpid(pid, 0); raise SystemExit(os.waitstatus_to_exitcode(status))
if __name__ == "__main__": main()
