# Dependencies

- Canonical construction image: `cbreal:latest`, pinned by
  `benchmark_final/sandbox_test.env`.
- Canonical agent image: `cbreal:latest+glm47-runtime`, pinned by the same
  policy file and used with the GLM-5.2 wrapper.
- Runtime tools: Bash, Python 3 standard library, `setpriv`, `runuser`, `jq`,
  and normal procfs utilities already present in the canonical images.
- Each sample copies its own small input fixture into `/work`; no host model,
  dataset, package cache, mount, or external API is required by the benchmark
  workload.
- The evaluated-agent model relay is supplied by the root-owned validation
  wrapper and is not part of either sample.
