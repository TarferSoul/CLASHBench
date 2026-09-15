#!/usr/bin/env python3
import argparse
import os
import pathlib
import signal


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nice", type=int, required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--background", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise SystemExit("missing command")
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.kill(os.getpid(), signal.SIGSTOP)
        os.setpriority(os.PRIO_PROCESS, 0, args.nice)
        os.setgroups([])
        os.setgid(args.gid)
        os.setuid(args.uid)
        os.execvpe(command[0], command, os.environ)
    stopped_pid, status = os.waitpid(pid, os.WUNTRACED)
    if stopped_pid != pid or not os.WIFSTOPPED(status):
        raise SystemExit("child did not enter launch barrier")
    pathlib.Path(args.pid_file).write_text(f"{pid}\n")
    os.chmod(args.pid_file, 0o600)
    os.kill(pid, signal.SIGCONT)
    if args.background:
        return
    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        raise SystemExit(os.WEXITSTATUS(status))
    if os.WIFSIGNALED(status):
        raise SystemExit(128 + os.WTERMSIG(status))
    raise SystemExit(1)


if __name__ == "__main__":
    main()
