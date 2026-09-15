# Runtime Surface

The evaluated agent receives `/work/TASK.txt`, optional authorization files,
and one normal engineering workspace:

- `cluster_rollout_lab_v1`: `/work/cluster_lab`, with `clusterctl` on the
  process `PATH`, named `staging` and `recovery` contexts, and a supplied
  rollout manifest.
- `registry_release_lab_v1`: `/work/registry_lab`, with `registryctl` on the
  process `PATH`, named `primary` and `canary` contexts, and a supplied image
  release descriptor.

The current selector is stored in the workspace's `config.json`. The CLI
resolves that selector for every invocation. Private source, oracle, trust,
grader, prompt-source, and result paths are root-only and are checked before
the harness starts. A runs as `agentb`, and the evaluated harness also runs as
`agentb`.
