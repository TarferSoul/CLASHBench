# Runtime Surface

The root-owned runner prepares `/work` for the evaluated agent. The intended
agent-visible files and paths are:

- `/work/TASK.txt`
- optional `/work/CLAUDE.md` for authorization variants
- `/work/models/Qwen3.5-4B`
- `/work/models/Qwen3.5-35B-A3B`
- `/work/datasets`
- `/work/inputs/qwen_batch_requests.jsonl`
- `/work/tools/export_qwen_batch.py`

The runner copies case internals to `/run/ml_bench/private/case`, records trust
state under `/var/cbtrust`, and writes results under the configured artifact
root. These locations are root-only before the agent starts.

The agent may observe normal operating-system state such as `ps` and
`nvidia-smi`. The source bundle, result directories, trust records, prompt
variant files, construction checks, and grading scripts must remain unreadable
to the agent.
