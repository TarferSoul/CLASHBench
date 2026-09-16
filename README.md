# CLASHBench

Docker-only evaluation of agents when a requested task conflicts with an
incumbent task. This checkout includes **238 real CPU system-resource cases**,
their fixtures, prompts, independent graders, and the case inventory.

## Quickstart: Run a Real Case

You need Linux, Docker, Python 3.10+, and an API key for your chosen model.
The quickstart case uses 2 CPUs and 2 GiB RAM. The full CPU suite requires
Docker to have at least 16 CPUs available; individual cases request up to
11 GiB RAM. Allow additional host memory and disk space for Docker and fixtures.
The CPU image occupies approximately 19.2 GB after extraction.
Run disk/I/O cases on idle local storage; their timing controls are part of
the case definitions.
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

For a private repository/package, authenticate GitHub access and run
`docker login ghcr.io` with a token that has `read:packages` before pulling.
See [VALIDATION.md](docs/VALIDATION.md) for the tested cases and image identity.

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

The repository bundles 238 CPU cases in `benchmark/inventory.json` and 10 GPU
cases in `benchmark/gpu-inventory.json`. Daily-life cases are not yet bundled.
GPU evaluation additionally needs a suitable dedicated GPU, NVIDIA Container
Toolkit, a prepared GPU image, and the separately downloaded assets below.
See [GPU.md](docs/GPU.md) for the case list, runtime versions, and mount configuration.

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

The 35B revision is taken from the original runner. The 4B command downloads
the upstream default revision; record the resolved revision for your run and
use `--revision` to repeat that download exactly. Building the GPU image does
not download model weights.

### GPU task-data downloads (outside the image)

GPU workloads use processed training data separately from the runtime image:

| Input | Required files |
|---|---|
| [ToolMind](https://huggingface.co/datasets/jinjinyien/CLASHBench-ToolMind) | `toolmind50k_direct_plain.json`, `dataset_info.json` |
| [Agentic safety](https://huggingface.co/datasets/AI45Research/APP1-Agentic-Safety-SFT-Data) | `agentic_safety_sft.json` (dataset metadata is supplied by the case) |

Download the Agentic Safety file at the pinned revision below. Its SHA-256
matches the original GPU benchmark input exactly:

```bash
python -m pip install huggingface_hub
hf download AI45Research/APP1-Agentic-Safety-SFT-Data \
  agentic_safety_sft.json --repo-type dataset \
  --revision 6ed56799527517de7868314abd9b6b8e7e9e2105 \
  --local-dir data/gpu-tasks
printf '%s  %s\n' \
  8ea135f5c120d059be19a3c20b789ab469e37d77299952dc84cb3d1cd7d76376 \
  data/gpu-tasks/agentic_safety_sft.json | sha256sum --check
export ACB_GPU_DATA_DIR="$PWD/data/gpu-tasks"
```

Download the frozen 50,000-record ToolMind input and its LlamaFactory metadata:

```bash
hf download jinjinyien/CLASHBench-ToolMind \
  toolmind50k_direct_plain.json dataset_info.json SHA256SUMS \
  --repo-type dataset --revision 360cb6bf9a9f51e4c18c6dd2a4ccbb75e7936e0f \
  --local-dir data/gpu-tasks
(cd data/gpu-tasks && sha256sum --check SHA256SUMS)
```

The original filename `toolmind_fullfilter50k_direct_plain_train.json` has
identical bytes. Cases that require that filename can use a local alias:

```bash
ln -sfn toolmind50k_direct_plain.json \
  data/gpu-tasks/toolmind_fullfilter50k_direct_plain_train.json
```

The supplied `dataset_info.json` defines both ToolMind dataset names. Use each
case's metadata for the Agentic Safety workload. An arbitrary upstream
ToolMind download does not reproduce this processed training input.

Model and task-data directories are mounted read-only through the GPU case
inventory, as shown in [GPU.md](docs/GPU.md). The CPU quickstart and full CPU
suite require neither these training files nor the Qwen model weights.

### Run a bundled GPU case

On a dedicated H200 host with NVIDIA Container Toolkit, download the 4B model
above, export `ACB_QWEN4B_DIR`, and configure the agent API key as in the CPU
quickstart. This case uses bundled task fixtures and needs no ToolMind or
Agentic Safety download:

```bash
docker pull ghcr.io/tarfersoul/clashbench:gpu
python -m acb.cli list --inventory benchmark/gpu-inventory.json
python -m acb.cli run \
  --inventory benchmark/gpu-inventory.json \
  --cases qwen4b_quant_calibration_vs_training_smoke_v1 \
  --config configs/codex.local.json \
  --gpu-image ghcr.io/tarfersoul/clashbench:gpu --parallel 1
```

To run all 10 GPU cases, download both models and both datasets, export
`ACB_QWEN4B_DIR`, `ACB_QWEN35B_DIR`, and `ACB_GPU_DATA_DIR`, then replace the
case ID with `all`. Execution runs in the background and uses the same status
and summary commands as the CPU quickstart. Each case requests 32 CPUs,
64000 MiB RAM, and one GPU. The Docker GPU adapters have static/interface
checks; real GPU acceptance is tracked separately in [VALIDATION.md](docs/VALIDATION.md).

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
