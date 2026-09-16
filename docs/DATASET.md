# Dataset contract and release packaging

## Distribution

This repository ships 238 frozen CPU and 10 GPU system-resource cases under
`benchmark/`, including separate inventories, fixtures, prompts, graders, and file
checksums. A clone supplies these inputs directly; no separate CPU archive
download or internal storage path is required. `examples/` contains a separate
infrastructure smoke fixture, which must never be used as a model score.

The intended paper inventory is 248 system-resource cases (238 CPU and 10 GPU)
plus 20 daily-life cases. The historical everyday staging directory has 21
entries; its count must not be used as the release selection. The maintainer
must freeze the exact 20-case selection before publishing that archive.

The GPU inventory is `benchmark/gpu-inventory.json`. Its runners use the
packaged runtime, read-only external model/data mounts, and configured native
agent adapters. Legacy internal API relays are removed. Each case records
original source hashes and release hashes; prompts, fixtures, and graders are
unchanged. The two large training datasets are external downloads. ATBench
inputs and other small task fixtures are bundled. Three source cases have no
standalone construction oracle and explicitly reject oracle mode. GPU Docker
acceptance remains pending; original manifest validation describes historical
runs, not acceptance of these Docker adapters.

The CPU release retains the original case limits, task definitions, and task
and peer graders. Eight runner fallback artifact paths were changed from
historical cluster paths to `/run/acb-results`. Two authoritative-context
oracles wait for `SIGSTOP` delivery before asserting the stopped process state;
the expected state and grading rules are unchanged. Four legacy runners use
canonical trace names and unique result filenames; two of those runners now
accept Codex through the installed wrapper under their original agent identity. `inventory.json` records
these portability changes and hashes every bundled file. The immutable source
dataset is not modified.

The container disables npm advisory/audit and update-notifier requests so
legacy npm 8 `--offline` fixture installs remain offline. This changes
background package-manager requests, not the task or peer grading criteria.

## Expected extracted layout

```text
benchmark/
  inventory.json
  bundles/<resource>/<configuration>/
    bin/run_case.sh
    samples/<case-id>/
      manifest.json
      public/prompts/task_query_p0_normal.txt
      private/...
```

Minimal inventory entry:

```json
{
  "schema_version": 1,
  "dataset": "CLASHBench-v1",
  "cases": [{
    "id": "case-id",
    "track": "system-resource",
    "bundle": "bundles/resource/configuration",
    "runner": "bin/run_case.sh",
    "resource": "port_bind",
    "occupancy_configuration": "exclusive_listener",
    "cpus": 2,
    "memory": "2Gi",
    "shm_size": "1Gi",
    "gpus": 0,
    "timeout_seconds": 900,
    "sha256": {"bin/run_case.sh": "REPLACE_WITH_SHA256"}
  }]
}
```

Paths must stay below the inventory directory. Case IDs are unique and use
letters, numbers, underscores, periods, or hyphens. The host copies each bundle
into its container; it never executes a case runner on the host. Optional
`pids_limit` and `environment` declare case-specific resource/runtime settings.
Do not put credentials in either field.

## Runner contract

The controller sets `BENCHMARK_SANDBOX=1`, `CASE`, `MODE`, `PROMPT`, `HARNESS`,
`HOST_ARTIFACT_ROOT`, and `AGENT_TIMEOUT_SECONDS`. `PROMPT` is `p0` or `p4`;
Preservation uses `p0` with the external preservation instruction.

A portable runner must:

1. Keep private scripts, trust state, and result directories root-owned and
   inaccessible to the agent. Start the incumbent using its intended identity.
2. Verify readiness, health, resource occupancy, and the agent's ability to
   affect the intended incumbent before invoking the harness.
3. Stage `/work/TASK.txt` and run `codex`, `claude`, or `opencode` as `agentb`.
   The installed wrappers select the configured provider/model and emit JSONL.
4. Capture that stdout in `evidence/agent_trace.txt` and stderr separately.
5. Write exactly one `result.json` below `HOST_ARTIFACT_ROOT`, with integer
   `agent_rc`, `task_ok`, and `peer_ok`. Preserve independent grading evidence.
6. Stop only its own incumbent/fixture processes after grading. Docker removal
   supplies the final per-run cleanup boundary.

```json
{"agent_rc": 0, "task_ok": 1, "peer_ok": 0,
 "visibility_ok": 1, "actionability_ok": 1}
```

Legacy bundles that overwrite the installed CLI wrappers, have no enabled agent
mode, omit the structured result, or rely on hard-coded external paths need a
portability adapter before evaluation. This runner fails such attempts rather
than interpreting them as safe. Do not patch graders or weaken conflicts to
make a portability test pass.

## Maintainer export

For a local frozen system-resource dataset with `index/samples.tsv`:

```bash
python -m acb.export_dataset \
  --source /path/to/frozen/dataset \
  --output data/staging \
  --cases all
python -m acb.cli list --inventory data/staging/inventory.json
```

The exporter copies bundles and their exact limits, computes file checksums,
and leaves source files unchanged. It does not upload anything or claim the
bundle is portable. Select a small subset first with comma-separated case IDs.
The output must be a new directory outside the source dataset.

Before distributing a release archive, validate every selected case using its
Docker oracle and an actual native harness, audit bundled data/third-party
binary redistribution permissions, remove internal endpoints and absolute
paths from release metadata, and publish an immutable archive checksum. Keep
training data and model weights in separately licensed downloads where needed.
