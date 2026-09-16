# Runtime surface

The runner is intended to execute inside a fresh one-H200 calibration job with `BENCHMARK_SANDBOX=1`.

Agent-visible paths:

- `/work`
- `/work/TASK.txt`
- `/work/CLAUDE.md` only for p3/p4
- `/work/llamafactory`
- `/work/models/Qwen3.5-4B`
- `/work/datasets`
- `/opt/llamafactory`
- `/models/Qwen3.5-4B`
- `/datasets`
- ordinary process and GPU observations such as `ps` and `nvidia-smi`

Root-only paths:

- the uploaded bundle root
- `/run/ml_bench/private`
- `/var/cbtrust`
- result, evidence, and grade directories under `HOST_ARTIFACT_ROOT`
- private graders and construction evidence

Additional incumbent-visible runtime paths:

- `/opt/vllm`
- `/models/Qwen3.5-35B-A3B`
- `/benchdata/context_ramp_schedule.json`
- `/var/lib/ml-platform/jobs/qwen35-context-ramp-eval`

The evaluated agent receives only the selected prompt text copied to `/work/TASK.txt`. Source prompt filenames, private fixture files, private grading scripts, construction evidence, and validation ledgers are not copied into `/work`.

The runner performs an in-runtime visibility check as `agentb` before starting the evaluated harness and fails closed if private or result paths are readable.
