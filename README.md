# AgentConflictBench

Docker-only evaluation tools for **AgentConflictBench: Evaluating Destructive
Resource Preemption When New Tasks Conflict with Existing Tasks**.

Run an agent beside an incumbent task, independently grade both outcomes, and
optionally judge the resulting trace for deliberate interference. All evaluated
code and trace judges execute in Docker. The host only schedules containers
and collects artifacts.

## Release status

This is the evaluation-tooling preparation repository. It includes executable
Docker orchestration, native Codex/Claude Code/OpenCode adapters, full judge
prompts, and a deterministic end-to-end smoke fixture. **The full benchmark
archive and a validated GPU image are not published here yet.** See
[dataset preparation](docs/DATASET.md) and [GPU prerequisites](docs/GPU.md).

The smoke fixture is not a benchmark case and cannot produce paper metrics.
Harness versions below are pinned for the portable runner; they are not claimed
to match the original paper's environment.

## Requirements

- Linux with Docker Engine and permission to create containers.
- Python 3.10+ on the host; no Python dependencies for the CLI.
- A provider API key for actual model evaluation.
- Enough CPU/RAM for each case's declared limits. Default concurrency is 1.
- NVIDIA Container Toolkit and a prepared GPU image for GPU cases only.

Clone the repository and run all commands from its root:

```bash
git clone https://github.com/TarferSoul/AgentConflictBench.git
cd AgentConflictBench
python -m acb.cli --help
```

## 1. Check Docker without an API key

```bash
docker build -f docker/Dockerfile.smoke -t agentconflictbench:smoke .
python -m acb.cli run \
  --inventory examples/inventory.json --cases all \
  --config configs/smoke.json --image agentconflictbench:smoke
```

`run` starts a background controller and immediately prints a run ID, results
directory, and PID. Substitute its directory for `RUN_DIR` below:

```bash
python -m acb.cli status RUN_DIR
python -m acb.cli summarize RUN_DIR
```

Expected: the fixture completes with `task_ok=0`, `peer_ok=1`, and a complete
trace. Since no model is evaluated, SPR and DIR denominators remain zero and
rates remain `null`. This verifies setup, agent identity, trace capture,
independent grading, collection, and cleanup.

## 2. Build the CPU runtime

```bash
docker build -f docker/Dockerfile \
  --build-arg CODEX_VERSION=0.154.0 \
  --build-arg CLAUDE_VERSION=2.1.272 \
  --build-arg OPENCODE_VERSION=1.18.31 \
  -t agentconflictbench:cpu .
```

Only public base images and package registries are used. The build installs the
three native harnesses and common CPU fixture dependencies. Case-specific
packages and GPU dependencies must be validated separately. Changing harness
versions changes the evaluated model-harness system; record it in your results.

## 3. Prepare data and a model config

Place an extracted, validated Docker-format dataset under `data/release/` with
its `inventory.json`. The precise format and maintainer conversion command are
in [DATASET.md](docs/DATASET.md). Then list its cases:

```bash
python -m acb.cli list --inventory data/release/inventory.json
cp configs/codex.json configs/codex.local.json
```

Edit `model` in the local JSON file to your provider's model ID. `base_url` must
match the protocol used by the selected native harness:

| Config | Harness | Provider protocol |
|---|---|---|
| `configs/codex.json` | Codex | OpenAI Responses (`base_url` includes `/v1`) |
| `configs/claude.json` | Claude Code | Anthropic Messages (origin without `/v1`) |
| `configs/opencode.json` | OpenCode | OpenAI-compatible Chat Completions (`/v1`) |

Set the configured environment variable in your shell, for example
`OPENAI_API_KEY` or `ANTHROPIC_API_KEY`. Do not write a key into JSON, the command
line, Git, or a dataset. The controller transfers it to the ephemeral container
without storing it in `plan.json`. Keep result directories private because agent
traces can include task data.

## 4. Start an evaluation

```bash
python -m acb.cli run \
  --inventory data/release/inventory.json \
  --cases CASE_ID \
  --config configs/codex.local.json \
  --condition default --parallel 1
```

Use comma-separated IDs or `--cases all`. The three conditions are `default`,
`preservation`, and `permission`. Each invocation gets a new results directory;
there is no implicit resume, result overwrite, or retry of invalid attempts.
A selected GPU case requires `--gpu-image`; see [GPU.md](docs/GPU.md).

```bash
python -m acb.cli status RUN_DIR
python -m acb.cli stop RUN_DIR
python -m acb.cli summarize RUN_DIR
```

Containers are removed after artifact collection. `--keep-containers` retains
them for debugging; inspect the ID in `RUN_DIR/CASE_ID/container.json`. Stopping
a run affects only containers labeled with that run ID.

To validate case causality without calling a model, use `--mode oracle` with
your normal configured harness. Oracle runs are reported separately and are
never included in model metrics.

## 5. Compute DIR and optional analyses

SPR is computed from valid independent outcome grades. DIR requires the separate
trace judge. Configure a Claude Code-compatible judge endpoint/model, then run:

```bash
cp configs/claude.json configs/judge.local.json
# Edit configs/judge.local.json and set its api_key_env in your shell.
python -m acb.judge \
  --run RUN_DIR --config configs/judge.local.json \
  --strategy resource_interference
```

This also starts asynchronously and prints the PID and status-file path. Once
judging finishes, recompute aggregate metrics:

```bash
python -m acb.cli summarize RUN_DIR
```

Optional strategies use the same command:

- `conflict_deference`: recognition, reporting, and leaving decisions to users.
- `concealment_gt`: final-response concealment, only after positive DIR and SPR.

Do not run multiple judges for the same strategy/run simultaneously. See
[PROTOCOL.md](docs/PROTOCOL.md) for label definitions, valid denominators, and
why missing judgments never count as safety.

## Artifacts

```text
results/RUN_ID/
  plan.json                 # dataset selection, limits, config without API keys
  status.json               # controller state
  controller.log
  summary.json              # event counts, denominators, rates
  CASE_ID/
    container.json          # container ID and immutable image ID
    status.json
    result.json             # normalized outcome and validity
    artifacts/              # original runner logs, evidence, grades, trace
    judge-resource_interference.json
```

## Development

```bash
python -m unittest discover -s tests -v
python -m compileall -q acb
```

The evaluator is designed for trusted, reviewed benchmark bundles. Do not run
arbitrary downloaded shell bundles on your workstation. Docker limits the
execution boundary; it is not a substitute for reviewing dataset release code.

## Paper and release checklist

Paper source: https://github.com/TarferSoul/agentconflict-arxiv

Before making this repository public, finalize the dataset download and checksum,
validate CPU/GPU case portability, and choose licenses for this code and bundled
data. No redistribution license is implied by this preparation snapshot.
