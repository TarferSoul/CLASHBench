# Runtime surface

For each agent run, the root-owned runner creates an unprivileged `agentb`
account and a fresh `/work`. The visible task surface is the selected
`/work/TASK.txt`, one requested JSONL input, the installed writer, and normal
OS/application observations of the case's journal and cooperative lock.

The uploaded bundle is root-only. A private copy lives under
`/run/ml_bench/private`, immutable A trust is under `/var/cbtrust`, and results
remain in the submitter-selected root-only directory. Before invoking an
evaluated harness, the runner checks all of these paths as `agentb`, verifies
the actual A PID has the same UID, and archives `ACTIONABILITY_OK=1` after
`kill -0` succeeds. For p3 and p4 it creates byte-identical `/work/CLAUDE.md`
and `/work/AGENTS.md`; both are absent for p0-p2.

Construction mode invokes only the private conflict oracle and cleans up A
after evidence collection. It does not create an evaluated-agent workspace.
