# CLASHBench

[Dataset on Hugging Face](https://huggingface.co/datasets/jinjinyien/CLASHBench)
| [Paper](https://arxiv.org/abs/2609.19892)

CLASHBench evaluates how AI agents handle a user request that conflicts with
an existing task or commitment. An agent may need a resource already used by
another workload, or be asked to change a reservation that someone else relies
on. The benchmark measures whether the agent completes the requested task,
whether the incumbent task is harmed, and whether the agent deliberately
intervenes in the conflict.

Each case runs in an isolated Docker container with executable tools and
independent graders for the requested and incumbent tasks. Agent traces support
further analysis of conflict recognition, disclosure, and intervention. The
same tasks can be evaluated under default, preservation, and permission
instructions using Codex, Claude Code, or OpenCode.

The repository includes **268 cases**:

| Suite | Cases | Scenarios | Inventory |
|---|---|---|---|
| CPU system resources | 238 | Competing processes, locks, storage, and shared configuration | `benchmark/inventory.json` |
| GPU system resources | 10 | Training and inference workloads competing for GPU memory | `benchmark/gpu-inventory.json` |
| Daily life | 20 | Conflicting bookings, household resources, and personal commitments | `benchmark/daily-life-inventory.json` |

## Installation

### 1. Install the Python Package

Use Linux with Python 3.10+ and a running Docker Engine. The Python package is
the host controller; benchmark workloads and native agent tools run inside the
images. Run the following commands from the machine that will host Docker:

```bash
git clone https://github.com/TarferSoul/CLASHBench.git
cd CLASHBench
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --index-url https://pypi.org/simple -e .
docker info
```

The package has no additional Python runtime dependencies. Use `clashbench`
or `python -m clashbench` from this checkout. For GPU asset downloads, also
install the Hugging Face CLI in the same environment:

```bash
python -m pip install --index-url https://pypi.org/simple huggingface_hub
```

### 2. Download the Docker Images

| Suite | Image | Additional downloads |
|---|---|---|
| CPU and daily life | `ghcr.io/tarfersoul/clashbench:cpu` | None; fixtures, tools, and graders ship with the repository |
| GPU | `ghcr.io/tarfersoul/clashbench:gpu` | Qwen workload models and task data as required by the case |

```bash
# CPU and daily-life evaluation
docker pull ghcr.io/tarfersoul/clashbench:cpu

# GPU evaluation
docker pull ghcr.io/tarfersoul/clashbench:gpu
```

Pull only the image needed for your suite. Native Codex, Claude Code, and
OpenCode tools are already installed in the images. The CPU image occupies
approximately 19.2 GB after extraction; the GPU image approximately 28.7 GB,
excluding model weights and datasets.

For a private repository/package, authenticate GitHub access and run
`docker login ghcr.io` with a token that has `read:packages` before pulling.

Host resources depend on the selected case:

| Suite | CPU and RAM per case | GPU requirement |
|---|---|---|
| CPU quickstart | 2 CPUs, 2 GiB RAM | None |
| Full CPU suite | Up to 16 CPUs and 11 GiB RAM | None |
| Daily life | 4 CPUs, 4 GiB RAM | None |
| GPU | 32 CPUs, 64000 MiB RAM | One dedicated H200 and NVIDIA Container Toolkit |

Allow additional memory and disk space for Docker, fixtures, model weights,
and outputs. Run disk/I/O cases on idle local storage. GPU hosts need an NVIDIA
driver compatible with the packaged CUDA runtimes; see [GPU.md](docs/GPU.md).

CPU and daily-life users can skip the next two download sections and proceed
to **Configure the Agent API**. GPU users should use the per-case requirements
in [GPU.md](docs/GPU.md); running all 10 cases requires both Qwen models and
both task datasets.

### 3. GPU Workload Models (GPU Only)

GPU workload models are separate from the agent model configured in
`configs/*.json`. Download the official
[Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) and, for cases that require
it, [Qwen3.5-35B-A3B](https://huggingface.co/Qwen/Qwen3.5-35B-A3B):

```bash
export HF_ENDPOINT=https://huggingface.co
hf download Qwen/Qwen3.5-4B --local-dir data/models/Qwen3.5-4B
hf download Qwen/Qwen3.5-35B-A3B \
  --revision b1fc3d59ae0ab1e4279e04a8dd0fc4dc361fc2b6 \
  --local-dir data/models/Qwen3.5-35B-A3B
export CLASHBENCH_QWEN4B_DIR="$PWD/data/models/Qwen3.5-4B"
export CLASHBENCH_QWEN35B_DIR="$PWD/data/models/Qwen3.5-35B-A3B"
```

The 35B revision is taken from the original runner. The 4B command downloads
the upstream default revision; record the resolved revision for your run and
use `--revision` to repeat that download exactly. Building the GPU image does
not download model weights.

### 4. GPU Task Data (GPU Only)

GPU workloads use processed training data separately from the runtime image:

| Input | Required files |
|---|---|
| [ToolMind](https://huggingface.co/datasets/jinjinyien/CLASHBench-ToolMind) | `toolmind50k_direct_plain.json`, `dataset_info.json` |
| [Agentic safety](https://huggingface.co/datasets/AI45Research/APP1-Agentic-Safety-SFT-Data) | `agentic_safety_sft.json` (dataset metadata is supplied by the case) |

Download the Agentic Safety file at the pinned revision below. Its SHA-256
matches the original GPU benchmark input exactly:

```bash
export HF_ENDPOINT=https://huggingface.co
hf download AI45Research/APP1-Agentic-Safety-SFT-Data \
  agentic_safety_sft.json --repo-type dataset \
  --revision 6ed56799527517de7868314abd9b6b8e7e9e2105 \
  --local-dir data/gpu-tasks
printf '%s  %s\n' \
  8ea135f5c120d059be19a3c20b789ab469e37d77299952dc84cb3d1cd7d76376 \
  data/gpu-tasks/agentic_safety_sft.json | sha256sum --check
export CLASHBENCH_GPU_DATA_DIR="$PWD/data/gpu-tasks"
```

Download the frozen 50,000-record ToolMind input and its LlamaFactory metadata:

```bash
export HF_ENDPOINT=https://huggingface.co
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

### 5. Configure the Agent API

The agent being evaluated uses your model provider's API. Its API model is
separate from the local Qwen models used by GPU workloads.

```bash
cp configs/codex.json configs/codex.local.json
```

In `configs/codex.local.json`, replace `YOUR_MODEL` with the model ID and set
`base_url` to your provider's OpenAI Responses endpoint (including `/v1`).
Leave `api_key_env` as `OPENAI_API_KEY`; supply the key through that environment
variable, not in the JSON file. For an interactive shell:

```bash
read -rsp 'API key: ' OPENAI_API_KEY; echo
export OPENAI_API_KEY
```

## Run Evaluations

### CPU Quickstart

After installation and API configuration, run one real case:

```bash
python -m clashbench run --config configs/codex.local.json \
  --cases cluster_access_reconciler_vs_recovery_preflight_v1
```

This is a real benchmark case: an existing workspace access sidecar owns the
shared cluster context, while the agent is asked to complete a conflicting
recovery preflight. The agent uses real tools and the two task outcomes are
independently graded. This is not the smoke fixture.

The command starts in the background and prints a `run_id`, result directory,
and controller PID. Substitute the printed directory for `RUN_DIR`:

```bash
python -m clashbench status RUN_DIR
python -m clashbench summarize RUN_DIR
```

A successful evaluation has `evaluation_valid: 1`. `task_ok` and `peer_ok` in
the case's `result.json` show whether the requested and incumbent tasks passed.
An agent may preserve the incumbent, preempt it, or fail the requested task;
none of those outcomes by itself means the evaluator failed. Invalid runs
include diagnostics and never count as safe behavior.

### Full CPU Suite

```bash
python -m clashbench list
python -m clashbench run --config configs/codex.local.json --parallel 1
```

The default inventory is `benchmark/inventory.json`, the default selection is
all 238 CPU cases, and the default image is
`ghcr.io/tarfersoul/clashbench:cpu`. Use `--cases ID1,ID2` to select cases and
`--image IMAGE` to use a pinned image digest or a locally built image. Limits
vary by case; budget CPU, RAM, disk, and API usage before increasing concurrency.

### Daily-Life Cases

These cases use the same CPU image and API configuration as the quickstart.
All task data, command-line tools, agent skills, and graders are bundled;
there are no extra model or dataset downloads. Each case requests 4 CPUs and
4 GiB RAM.

```bash
python -m clashbench list --inventory benchmark/daily-life-inventory.json
python -m clashbench run \
  --inventory benchmark/daily-life-inventory.json \
  --cases roommate_laundry_slot_v1 \
  --config configs/codex.local.json --parallel 1
```

Replace the case ID with `all` to run all 20. The run starts in the background;
use the same `status` and `summarize` commands shown above.
See [DAILY_LIFE.md](docs/DAILY_LIFE.md) for
the complete case list and task surfaces.

### GPU Cases

On a dedicated H200 host with NVIDIA Container Toolkit, download the 4B model
above, export `CLASHBENCH_QWEN4B_DIR`, and configure the agent API key as described
in the installation section. This case uses bundled task fixtures and needs
no ToolMind or Agentic Safety download:

```bash
python -m clashbench list --inventory benchmark/gpu-inventory.json
python -m clashbench run \
  --inventory benchmark/gpu-inventory.json \
  --cases qwen4b_quant_calibration_vs_training_smoke_v1 \
  --config configs/codex.local.json \
  --gpu-image ghcr.io/tarfersoul/clashbench:gpu --parallel 1
```

To run all 10 GPU cases, download both models and both datasets, export
`CLASHBENCH_QWEN4B_DIR`, `CLASHBENCH_QWEN35B_DIR`, and `CLASHBENCH_GPU_DATA_DIR`, then replace the
case ID with `all`. Execution runs in the background and uses the same status
and summary commands as the CPU quickstart. Each case requests 32 CPUs,
64000 MiB RAM, and one dedicated H200 GPU.

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
python -m clashbench run --config configs/claude.local.json \
  --cases registry_session_reconciler_vs_sbom_attestation_v1 \
  --condition preservation
```

Conditions are `default`, `permission`, and `preservation`. Each invocation
creates a new run; there is no implicit resume or overwrite.

```bash
python -m clashbench stop RUN_DIR
```

Containers are removed after artifact collection. Use `--keep-containers` for
local debugging and inspect the container ID in `RUN_DIR/CASE_ID/container.json`.

## Metrics and Trace Judging

SPR is computed automatically from valid task/peer grades. DIR additionally
requires a trace judge. Configure a Claude Code-compatible endpoint in
`configs/judge.local.json` using `configs/claude.json` as the template, then run:

```bash
python -m clashbench.judge --run RUN_DIR --config configs/judge.local.json \
  --strategy resource_interference --image ghcr.io/tarfersoul/clashbench:cpu
```

Judging also starts in the background. After its status file reports
`finished`, run `python -m clashbench summarize RUN_DIR` again. DIR remains `null`
until valid judge results exist; it is never inferred from task success alone.
Optional strategies are `conflict_deference` and `concealment_gt`.
See [PROTOCOL.md](docs/PROTOCOL.md) for the metric definitions.

## Citation

If you use CLASHBench in your research, please cite our paper:

```bibtex
@misc{xie2026clashbench,
  title = {{ClashBench}: Conflicts Leading Agents to Seize and Harm},
  author = {Yuejin Xie and Yu Li and Dadi Guo and Qingyu Liu and Yuqian Fu and Yanwei Fu and Yujiu Yang and Xia Hu and Dongrui Liu},
  year = {2026},
  eprint = {2609.19892},
  archivePrefix = {arXiv},
  url = {https://arxiv.org/abs/2609.19892}
}
```
