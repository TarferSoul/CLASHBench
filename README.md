# CLASHBench

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

### What can I run now?

| Path | Ready to run from this checkout? | Required inputs |
|---|---|---|
| Docker smoke (Section 1) | Yes | Docker; builds from a public base, no API key or downloaded data |
| Real CPU evaluation | Not yet as a standalone release | Validated benchmark bundle with `inventory.json`, CPU image, and provider config/key |
| Real GPU evaluation | Not yet | Validated GPU image and benchmark bundle, model weights, prepared task data, and a suitable GPU |

**For a fresh clone, start with Section 1.** The later evaluation commands are
for use after the listed inputs are available. This repository does not yet
provide `data/release/inventory.json` or a downloadable full benchmark archive.
The CPU GHCR package is private; authorized users can pull it, or build locally
using Section 2. GPU task-data download commands require the release URL and
checksum, which are still pending.

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
git clone https://github.com/TarferSoul/CLASHBench.git
cd CLASHBench
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

## 2. Pull or build the CPU runtime

The CPU image is published to GitHub Container Registry. Pull it and create the
local tag expected by the CLI:

```bash
docker pull ghcr.io/tarfersoul/agentconflictbench:cpu
docker tag ghcr.io/tarfersoul/agentconflictbench:cpu agentconflictbench:cpu
```

The package is initially private. Authenticate with `docker login ghcr.io`
using your GitHub username and a token with `read:packages` and access to the
package. Enter the token at the password prompt, not in a shell command.
Each publication also has a `cpu-<full-git-sha>` tag; pin its registry digest
for reproducible runs. Publication is triggered manually with the **Publish
CPU image** GitHub Actions workflow and only pushes after checks pass.

To build locally instead:

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

### GPU model downloads (outside the image)

GPU workload models are separate from the agent model configured in
`configs/*.json`. Download the official
[Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) and, for cases that require
it, [Qwen3.5-35B-A3B](https://huggingface.co/Qwen/Qwen3.5-35B-A3B):

```bash
python -m pip install huggingface_hub
hf download Qwen/Qwen3.5-4B --local-dir data/models/Qwen3.5-4B
hf download Qwen/Qwen3.5-35B-A3B \
  --revision b1fc3d59ae0ab1e4279e04a8dd0fc4dc361fc2b6 \
  --local-dir data/models/Qwen3.5-35B-A3B
export ACB_QWEN4B_DIR="$PWD/data/models/Qwen3.5-4B"
export ACB_QWEN35B_DIR="$PWD/data/models/Qwen3.5-35B-A3B"
```

The 35B revision is taken from the original runner. The original 4B revision
still needs to be pinned in the dataset release; the first command currently
downloads the upstream default revision. Record the resolved revision for a
run and use `--revision` once the release supplies it. These commands are
instructions only: building the GPU image does not download any weights.

### GPU task-data downloads (outside the image)

The GPU workloads use prepared ToolMind and agentic-safety training files,
including `toolmind50k_direct_plain.json`, `agentic_safety_sft.json`, and their
`dataset_info.json` metadata. **The prepared task-data archive and its download
URL/checksum have not been released yet.** An arbitrary upstream ToolMind
download does not reproduce these processed files.

When the release provides its archive URL and SHA-256, download and verify it
separately from the image:

```bash
# Set both values from the CLASHBench data release notes when published.
: "${CLASH_GPU_DATA_URL:?Set the published GPU task-data archive URL}"
: "${CLASH_GPU_DATA_SHA256:?Set its published SHA-256}"
mkdir -p data/gpu-tasks
curl --fail --location "$CLASH_GPU_DATA_URL" -o data/gpu-tasks.tar.gz
printf '%s  %s\n' "$CLASH_GPU_DATA_SHA256" data/gpu-tasks.tar.gz | sha256sum --check
tar -xzf data/gpu-tasks.tar.gz -C data/gpu-tasks
export ACB_GPU_DATA_DIR="$PWD/data/gpu-tasks"
```

Model and task-data directories are mounted read-only through the case
inventory, as shown in [GPU.md](docs/GPU.md). Both asset releases remain
separate from the runtime-image work.

### Benchmark bundles and agent configuration

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
