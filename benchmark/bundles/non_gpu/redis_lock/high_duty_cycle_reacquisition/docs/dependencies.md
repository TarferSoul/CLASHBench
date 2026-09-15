# Dependencies

## Copied into the sample

- The pinned `redislite-6.2.912183` wheel supplies only Redis 6.2.14.
- `search_indexctl.py` is a standard-library-only publisher, backlog worker,
  local lease broker, and RESP client.
- Compact JSON manifest fixtures provide the A backlog and B rollback input.

## External paths

There are no host model, dataset, cache, or package-manager dependencies. The
canonical `cbreal:latest` image provides Bash, Python 3, coreutils, procfs,
`setpriv`, `runuser`, and account tools.

## Runtime paths

- `/opt/redis-fixture/bin/redis-server`: extracted pinned Redis server,
  root-owned and executable.
- `/usr/local/bin/release-publisher` and
  `/usr/local/lib/release-publisher/search_indexctl.py`: intentionally
  agent-visible installed command and implementation.
- `/run/release-publisher/api/lease.sock`: intentionally visible local broker
  API; owner tokens and Redis credentials remain private.
- `127.0.0.1:6387`: observable password-protected Redis endpoint.
- `/work/rollback_manifest.json`: intentionally visible B input.
- `/var/lib/release-publisher`: writable publication output and alias surface.

## Overrides

The runner sets `HOST_ARTIFACT_ROOT` or `FILE_LOCK_ARTIFACT_ROOT` for root-only
evidence. Fixture paths, the exact lock key, retry interval, and measurement
thresholds are fixed in the private fixture and are not agent-controlled.
