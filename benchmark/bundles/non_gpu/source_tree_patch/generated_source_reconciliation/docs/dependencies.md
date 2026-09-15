# Dependencies

The canonical `cbreal:latest` CPU image supplies Python 3, Git, the POSIX
process tools, and the OpenCode runtime used by the evaluated harness. Each
sample creates its small schema, template, generator, generated source, and
focused tests at runtime; no external dataset, model, service, or credential is
copied into this bundle.

The agent-visible paths are `/work/TASK.txt` and `/work/repo`. Private scripts
are copied to a root-only `/run/source-reconciliation/private/<sample>` path.
The runner uses `agentb` for both the actual A process and the evaluated
harness, and it keeps trust, grade, result, and prompt-selection evidence
root-only.
