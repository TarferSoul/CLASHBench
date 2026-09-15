# CLASHBench

Docker-only evaluation of agents when a requested task conflicts with an
incumbent task. This checkout includes **238 real CPU system-resource cases**,
their fixtures, prompts, independent graders, and the case inventory.

## Quickstart: Run a Real Case

You need Linux, Docker, Python 3.10+, and an API key for your chosen model.
Benchmark scripts execute inside Docker; no dataset download or path editing
is needed for the bundled CPU cases.

```bash
git clone https://github.com/TarferSoul/CLASHBench.git
cd CLASHBench
docker pull ghcr.io/tarfersoul/clashbench:cpu
cp configs/codex.json configs/codex.local.json
```

In `configs/codex.local.json`, replace `YOUR_MODEL` with the model ID and set
`base_url` to your provider's OpenAI Responses endpoint (including `/v1`).
Leave `api_key_env` as `OPENAI_API_KEY`; supply the key through that environment
variable, not in the JSON file. For an interactive shell:

```bash
read -rsp 'API key: ' OPENAI_API_KEY; echo
export OPENAI_API_KEY
python -m acb.cli run --config configs/codex.local.json \
  --cases cluster_access_reconciler_vs_recovery_preflight_v1
```

This is a real benchmark case: an existing workspace access sidecar owns the
shared cluster context, while the agent is asked to complete a conflicting
recovery preflight. The agent uses real tools and the two task outcomes are
independently graded. This is not the smoke fixture.

The command starts in the background and prints a `run_id`, result directory,
and controller PID. Substitute the printed directory for `RUN_DIR`:

```bash
python -m acb.cli status RUN_DIR
python -m acb.cli summarize RUN_DIR
```

A successful evaluation has `evaluation_valid: 1`. `task_ok` and `peer_ok` in
the case's `result.json` show whether the requested and incumbent tasks passed.
An agent may preserve the incumbent, preempt it, or fail the requested task;
none of those outcomes by itself means the evaluator failed. Invalid runs
include diagnostics and never count as safe behavior.

### Run the bundled CPU suite

```bash
python -m acb.cli list
python -m acb.cli run --config configs/codex.local.json --parallel 1
```

The default inventory is `benchmark/inventory.json`, the default selection is
all 238 CPU cases, and the default image is
`ghcr.io/tarfersoul/clashbench:cpu`. Use `--cases ID1,ID2` to select cases and
`--image IMAGE` to use a pinned image digest or a locally built image. Limits
vary by case; budget CPU, RAM, disk, and API usage before increasing concurrency.

The package is private during release preparation. Authorized users can run
`docker login ghcr.io` with a token that has `read:packages`; public release
will remove that registry-login requirement. Image publication and case
validation status are recorded in [VALIDATION.md](docs/VALIDATION.md).

## Other Harnesses and Conditions

| Config template | Harness | Endpoint protocol |
|---|---|---|
| `configs/codex.json` | Codex | OpenAI Responses; URL includes `/v1` |
| `configs/claude.json` | Claude Code | Anthropic Messages; URL is the API origin |
| `configs/opencode.json` | OpenCode | OpenAI-compatible Chat Completions; URL includes `/v1` |

Copy your chosen template to `configs/NAME.local.json`, set the model and
endpoint, and export its `api_key_env`. Local configuration files are ignored
by Git. If your provider needs an outbound proxy, add
`"proxy_env": "HTTPS_PROXY"` and export `HTTPS_PROXY` on the host; the runner
passes it only to the native agent client.

```bash
python -m acb.cli run --config configs/claude.local.json \
  --cases registry_session_reconciler_vs_sbom_attestation_v1 \
  --condition preservation
```

Conditions are `default`, `permission`, and `preservation`. Each invocation
creates a new run; there is no implicit resume or overwrite.

```bash
python -m acb.cli stop RUN_DIR
```

Containers are removed after artifact collection. Use `--keep-containers` for
local debugging and inspect the container ID in `RUN_DIR/CASE_ID/container.json`.

## Metrics and Trace Judging

SPR is computed automatically from valid task/peer grades. DIR additionally
requires a trace judge. Configure a Claude Code-compatible endpoint in
`configs/judge.local.json` using `configs/claude.json` as the template, then run:

```bash
python -m acb.judge --run RUN_DIR --config configs/judge.local.json \
  --strategy resource_interference --image ghcr.io/tarfersoul/clashbench:cpu
```

Judging also starts in the background. After its status file reports
`finished`, run `python -m acb.cli summarize RUN_DIR` again. DIR remains `null`
until valid judge results exist; it is never inferred from task success alone.
Optional strategies are `conflict_deference` and `concealment_gt`.
See [PROTOCOL.md](docs/PROTOCOL.md) for the metric definitions.

## GPU Models and Task Data

The bundled inventory currently covers the 238 CPU cases. The 10 GPU cases
and the 20 selected daily-life cases are not included in this CPU release.
GPU evaluation additionally needs a suitable dedicated GPU, NVIDIA Container
Toolkit, a prepared GPU image, and the separately downloaded assets below.
See [GPU.md](docs/GPU.md) for runtime versions and mount configuration.

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

## Build and Validate Locally

The full CPU release image retains the original experiment's CPU dependencies.
Maintainers with access to the original base can build the native-tool layer
and release image:

```bash
docker build --network host -f docker/Dockerfile.gpu --target harnesses \
  -t clashbench:gpu-harnesses .
docker build -f docker/Dockerfile.cpu-release -t clashbench:cpu .
```

`docker/Dockerfile` remains a smaller public-base development image; it is not
claimed to contain every dependency used by the full CPU suite. Agent versions
are pinned to Codex 0.154.0, Claude Code 2.1.272, and OpenCode 1.18.31. Record the
image digest and model when reporting results.

For an infrastructure-only check without an API key:

```bash
docker build -f docker/Dockerfile.smoke -t agentconflictbench:smoke .
python tests/docker_smoke.py
python -m unittest discover -s tests -v
```

The smoke fixture does not contribute to benchmark metrics. To check a real
case's construction without calling a model, add `--mode oracle` to the real
case command. Oracle results are also excluded from model metrics.

## Artifacts and Scope

Runs are stored under `results/RUN_ID/`. `plan.json` records the case inventory,
model configuration without credentials, image reference, and resource limits.
Each case has `result.json`, status, container metadata, and collected evidence.
Keep result directories private because agent traces can contain task data.

The original dataset source is not changed by this release. See
[DATASET.md](docs/DATASET.md) for provenance and portability changes,
[VALIDATION.md](docs/VALIDATION.md) for verified coverage, and
[the paper repository](https://github.com/TarferSoul/agentconflict-arxiv).
Code and dataset redistribution licenses and public visibility still need to
be finalized before the public launch.
