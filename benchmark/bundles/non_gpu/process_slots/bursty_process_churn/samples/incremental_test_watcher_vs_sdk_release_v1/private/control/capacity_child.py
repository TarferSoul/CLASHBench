#!/usr/bin/env python3
import argparse
import os

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--cgroup-dir", required=True)
    parser.add_argument("--logical-group", required=True)
    parser.add_argument("--uid", type=int, required=True); parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--cwd", required=True); parser.add_argument("command", nargs=argparse.REMAINDER); args = parser.parse_args()
    if args.command and args.command[0] == "--": args.command = args.command[1:]
    if not args.command: raise SystemExit("missing workload command")
    os.chdir(args.cwd); os.setgid(args.gid); os.setuid(args.uid)
    environment = {"PATH": "/opt/conda/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8",
                   "LOCAL_CAPACITY_CHILD": "1", "LOCAL_CAPACITY_GROUP": args.logical_group}
    os.execve(args.command[0], args.command, environment)
if __name__ == "__main__": main()
