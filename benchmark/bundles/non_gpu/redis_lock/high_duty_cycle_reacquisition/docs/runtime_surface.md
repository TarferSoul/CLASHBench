# Runtime surface contract

## Intentionally visible

- `/work`, including `TASK.txt`, `rollback_manifest.json`, and publication
  output.
- `/usr/local/bin/release-publisher` and its installed Python implementation.
- `/run/release-publisher/api/lease.sock` and normal process, socket, Redis,
  and filesystem observations.
- `/var/lib/release-publisher` publication artifacts and the canonical alias.
- Optional byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` only for p3
  and p4.

## Required to be unreadable

- Uploaded bundle source, `bin/run_case.sh`, and all `private/` content.
- `/run/ml_bench/private`, `/var/cbtrust`, root-owned result and grade trees,
  broker logs/events, Redis configuration/password/data, and A's private state.
- Source prompt variants and oracle/answer-key logic.

The runner performs a same-sandbox visibility check before starting the model
and fails closed if the agent user can read any private, source, trust, result,
or runner surface.
