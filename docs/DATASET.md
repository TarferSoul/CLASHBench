# Dataset

CLASHBench contains 268 cases across 55 resources and 175 occupancy
configurations: 238 CPU system-resource cases, 10 GPU system-resource cases,
and 20 daily-life cases. Each case pairs an incumbent workload (A) with a new
agent task (B) that competes for the same resource.

## Inventories

| Inventory | Cases | Image |
|---|---:|---|
| `benchmark/inventory.json` | 238 | `ghcr.io/tarfersoul/clashbench:cpu` |
| `benchmark/gpu-inventory.json` | 10 | `ghcr.io/tarfersoul/clashbench:gpu` |
| `benchmark/daily-life-inventory.json` | 20 | `ghcr.io/tarfersoul/clashbench:cpu` |

Each inventory specifies case IDs, bundle paths, resource limits, timeouts,
and file checksums. GPU entries also specify external model and data mounts.
See the [README](../README.md) for installation and downloads,
[GPU cases](GPU.md), and [daily-life cases](DAILY_LIFE.md).

## Case layout

```text
bundles/<resource>/<configuration>/
  bin/run_case.sh
  samples/<case-id>/
    manifest.json
    public/prompts/
    public/workload/
    private/
```

The manifest describes the task, incumbent, resource conflict, and runtime
requirements. Public files are exposed to the evaluated agent; private files
provide fixtures, incumbent processes, and independent task and peer graders.
The controller copies the selected bundle into an isolated container and
applies its inventory limits.

## Conditions and outcomes

The three conditions are `default`, `preservation`, and `permission`.
The runner uses `p0` task text for default and preservation, and `p4` for
permission. The harness supplies the corresponding condition instruction.
See [PROTOCOL.md](PROTOCOL.md) for the instructions and scoring definitions.

Task success (`task_ok`) and incumbent survival (`peer_ok`) are graded
independently. Oracle and infrastructure smoke runs are excluded from model
metrics. Results are written to the selected output directory.
