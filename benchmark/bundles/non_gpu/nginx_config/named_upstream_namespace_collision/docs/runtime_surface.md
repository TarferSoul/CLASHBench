# Runtime Surface

The evaluated agent sees only `/work`, `/work/TASK.txt`, optional
byte-identical runner authorization files for p3/p4, and the staged service
directory for its selected case:

- `/work/registry_gateway` plus `/work/replay_pool` for the registry sample.
- `/work/telemetry_gateway` plus `/work/schema_sync` for the telemetry sample.

These paths contain the live nginx prefix, worker launcher, supplied include
snippets, logs, PID files, and request evidence needed for the engineering task.
Normal OS observations and local HTTP probes are also available.

The runner copies private fixtures to a root-only path under
`/run/ml_bench/private`, records trust state under `/var/cbtrust`, and stores
grader evidence under the root-owned result directory. It fails closed if
agentb can read the source bundle, private copy, trust state, or results.

