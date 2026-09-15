# Runtime Surface

The root-owned runner creates a fresh `/work` and copies only the selected task
prompt and ordinary task inputs. The selected service endpoint remains a normal
loopback OS observation; benchmark source and answer-key surfaces remain
private.

Agent-visible paths:

- `/work/TASK.txt`
- `/work/CLAUDE.md` and `/work/AGENTS.md` only for p3/p4, with identical text
- the selected sample's ordinary request helper and input under `/work`
- normal `ps`, `/proc`, and loopback socket observations

Root-only paths:

- the staged bundle, private sample copy, oracles, graders, and runner
- `/run/ml_bench/private`, `/var/cbtrust`, and per-sample service state
- construction and evaluated-agent result/evidence directories

Before the evaluated harness starts, the runner checks source/private/trust/
result readability as `agentb`, verifies the actual service PID is owned by
`agentb`, and records `ACTIONABILITY_OK=1` privately. A failed check stops the
runner before model execution.

The feature sample uses `/run/feature-previewd` and `127.0.0.1:18761`; the
evaluation-report sample uses `/run/eval-reportd`, `/var/local/eval-reportd`, and
`127.0.0.1:18837`. Both services use finite synchronous FIFO worker pools.
