#!/usr/bin/env python3
"""Pinned Redis 7 read/write lease client used by the construction fixture."""

import argparse
import json
import os
import secrets
import socket
import sys
import time


class Redis:
    def __init__(self, host, port, db=0, timeout=3.0):
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.sock.settimeout(timeout)
        if db:
            self.command("SELECT", str(db))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _readline(self):
        data = bytearray()
        while True:
            part = self.sock.recv(1)
            if not part:
                raise RuntimeError("redis connection closed")
            data.extend(part)
            if data[-2:] == b"\r\n":
                return bytes(data[:-2])

    def _reply(self):
        kind = self.sock.recv(1)
        if not kind:
            raise RuntimeError("redis reply missing")
        if kind in b"+-:":
            line = self._readline().decode()
            if kind == b"-":
                raise RuntimeError(line)
            return int(line) if kind == b":" else line
        if kind == b"$":
            size = int(self._readline())
            if size < 0:
                return None
            value = b""
            while len(value) < size + 2:
                value += self.sock.recv(size + 2 - len(value))
            return value[:size].decode()
        if kind == b"*":
            size = int(self._readline())
            if size < 0:
                return None
            return [self._reply() for _ in range(size)]
        raise RuntimeError(f"unsupported redis reply {kind!r}")

    def command(self, *args):
        payload = [f"*{len(args)}\r\n".encode()]
        for arg in args:
            raw = str(arg).encode()
            payload.append(f"${len(raw)}\r\n".encode())
            payload.append(raw + b"\r\n")
        self.sock.sendall(b"".join(payload))
        return self._reply()

    def eval(self, script, keys=(), args=()):
        return self.command("EVAL", script, len(keys), *keys, *args)


ACQUIRE_READ = """
local writer = redis.call('GET', KEYS[1])
if writer then return 0 end
if redis.call('SET', KEYS[2], ARGV[1], 'NX', 'EX', ARGV[2]) then
  redis.call('SADD', KEYS[3], ARGV[3])
  return 1
end
return 0
"""
RENEW_READ = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
  return 1
end
return 0
"""
RELEASE_READ = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('DEL', KEYS[1])
  redis.call('SREM', KEYS[2], ARGV[2])
  return 1
end
return 0
"""
ACQUIRE_WRITE = """
local members = redis.call('SMEMBERS', KEYS[2])
for _, token in ipairs(members) do
  if redis.call('EXISTS', KEYS[3] .. token) == 0 then
    redis.call('SREM', KEYS[2], token)
  end
end
if redis.call('SCARD', KEYS[2]) ~= 0 then return 0 end
if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'EX', ARGV[2]) then return 1 end
return 0
"""
RENEW_WRITE = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
  return 1
end
return 0
"""
RELEASE_WRITE = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('DEL', KEYS[1])
  return 1
end
return 0
"""


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        raise SystemExit(f"missing {name}")
    return value


def conn():
    return Redis(env("REDIS_HOST", "127.0.0.1"), env("REDIS_PORT", "6389"), int(env("REDIS_DB", "0")))


def keys():
    lock = env("LOCK_KEY")
    return {
        "writer": env("WRITER_KEY", lock + ":writer"),
        "readers": env("READER_SET_KEY", lock + ":readers"),
        "prefix": env("READER_OWNER_PREFIX", lock + ":reader:"),
    }


def token(prefix):
    return f"{prefix}-{os.getpid()}-{secrets.token_hex(8)}"


def acquire_read(r, owner, value, ttl, reader_token):
    k = keys()
    return int(r.eval(ACQUIRE_READ, (k["writer"], owner, k["readers"]), (value, ttl, reader_token))) == 1


def renew_read(r, owner, value, ttl):
    return int(r.eval(RENEW_READ, (owner,), (value, ttl))) == 1


def release_read(r, owner, value, reader_token):
    k = keys()
    return int(r.eval(RELEASE_READ, (owner, k["readers"]), (value, reader_token))) == 1


def acquire_write(r, value, ttl):
    k = keys()
    return int(r.eval(ACQUIRE_WRITE, (k["writer"], k["readers"], k["prefix"]), (value, ttl))) == 1


def renew_write(r, value, ttl):
    k = keys()
    return int(r.eval(RENEW_WRITE, (k["writer"],), (value, ttl))) == 1


def release_write(r, value):
    k = keys()
    return int(r.eval(RELEASE_WRITE, (k["writer"],), (value,))) == 1


def inspect_state(r):
    k = keys()
    members = r.command("SMEMBERS", k["readers"]) or []
    rows = []
    for member in sorted(members):
        owner = k["prefix"] + member
        rows.append({"token": member, "value": r.command("GET", owner), "pttl_ms": r.command("PTTL", owner)})
    return {
        "writer": r.command("GET", k["writer"]),
        "writer_pttl_ms": r.command("PTTL", k["writer"]),
        "reader_set": rows,
        "reader_count": len(rows),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=("ping", "reset", "inspect", "set-active", "get-active", "seed", "acquire-read", "renew-read", "release-read", "acquire-write", "renew-write", "release-write"))
    ap.add_argument("--value", default="")
    ap.add_argument("--token", default="")
    ap.add_argument("--ttl", type=int, default=6)
    ap.add_argument("--owner", default="")
    ap.add_argument("--generation", default="")
    args = ap.parse_args()
    r = conn()
    try:
        if args.command == "ping":
            print(r.command("PING"))
        elif args.command == "reset":
            print(r.command("FLUSHDB"))
        elif args.command == "inspect":
            print(json.dumps(inspect_state(r), sort_keys=True))
        elif args.command == "set-active":
            print(r.command("SET", env("ACTIVE_KEY"), args.value))
        elif args.command == "get-active":
            print(r.command("GET", env("ACTIVE_KEY")))
        elif args.command == "seed":
            r.command("FLUSHDB")
            r.command("SET", env("ACTIVE_KEY"), "schema_v1")
            r.command("SET", env("FENCE_KEY"), "0")
            r.command("SET", env("GENERATION_PREFIX") + "schema_v1", open(env("DATA_ROOT") + "/schema_v1.json").read())
            print(json.dumps({"active": "schema_v1", "fence": "0"}))
        elif args.command == "acquire-read":
            owner = args.owner or env("READER_OWNER_PREFIX") + args.token
            print(json.dumps({"acquired": acquire_read(r, owner, args.value or args.token, args.ttl, args.token)}))
        elif args.command == "renew-read":
            owner = args.owner or env("READER_OWNER_PREFIX") + args.token
            print(json.dumps({"renewed": renew_read(r, owner, args.value or args.token, args.ttl)}))
        elif args.command == "release-read":
            owner = args.owner or env("READER_OWNER_PREFIX") + args.token
            print(json.dumps({"released": release_read(r, owner, args.value or args.token, args.token)}))
        elif args.command == "acquire-write":
            print(json.dumps({"acquired": acquire_write(r, args.value or args.token, args.ttl)}))
        elif args.command == "renew-write":
            print(json.dumps({"renewed": renew_write(r, args.value or args.token, args.ttl)}))
        elif args.command == "release-write":
            print(json.dumps({"released": release_write(r, args.value or args.token)}))
    finally:
        r.close()


if __name__ == "__main__":
    main()
