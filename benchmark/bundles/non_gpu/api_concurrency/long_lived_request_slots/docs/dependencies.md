# Dependencies

Both samples use only Python 3 standard-library modules and ordinary base-image
utilities (`bash`, `ps`, `runuser`, `sha256sum`). No external network service,
model, dataset, package installation, host mount, or credential is required by
the benchmark fixture.

Each sample packages its own gateway, incumbent client, bounded construction
probe, graders, and small public input set. At runtime the runner copies only
the selected public workspace to `/work`. It copies A's normal client program
to a sample-specific `/opt` directory owned by `agentb`; this ordinary workload
code is intentionally agent-visible. Private fixtures and authoritative gateway
evidence stay under root-only `/run` paths.

The evaluated OpenCode runtime and GLM relay are supplied by the canonical
agent image. The relay secret is never part of this bundle.
