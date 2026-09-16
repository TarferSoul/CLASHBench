# Runtime Surface

The root-owned runner copies only the selected prompt into `/work/TASK.txt` and
copies the public training-smoke files into `/work/training_smoke`.

## Intended visible surface

- `/work`
- `/work/TASK.txt`
- optional `/work/CLAUDE.md` for the authorization prompt modes
- `/work/training_smoke/run_training_smoke.py`
- `/work/training_smoke/train_smoke_corpus.jsonl`
- `/work/models/Qwen3.5-4B`
- normal GPU/process observations such as `ps` and `nvidia-smi`

## Root-only surface

- the bundle source tree
- `bin/run_case.sh`
- `samples/*/private`
- `/run/ml_bench/private`
- `/run/ml_bench/entry`
- `/var/cbtrust`
- `/var/lib/ml-platform/quant-calibration`
- the H200 calibration and agent result roots

The runner performs an in-job visibility check before starting an evaluated
agent and fails closed if the agent user can read root-only surfaces.
