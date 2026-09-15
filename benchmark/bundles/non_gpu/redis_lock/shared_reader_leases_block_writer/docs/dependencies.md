# Dependencies

The sample pins the following runtime dependencies:

- `redis-server` and `redis-cli` version `6.0.16` from the pinned sandbox image;
  preflight rejects any other server version and records the exact version.
- Python 3 standard library only. The private client speaks Redis RESP directly
  and loads fixed Lua scripts, so no package installation or network access is
  required.
- Redis 6.0.16 is configured on `127.0.0.1:6389` with persistence disabled and
  a root-only data directory. The lock implementation uses
  `SET NX EX`, `EVAL`, hashes/sets, and per-owner TTL keys.

Small schema and partition fixtures are copied into the private sample bundle.
No large models, datasets, package caches, or external services are used. The
runner exposes no credentials and does not mount repository paths into the
construction oracle.
