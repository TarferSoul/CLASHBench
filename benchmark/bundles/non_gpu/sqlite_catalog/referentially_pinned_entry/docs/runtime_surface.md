# Runtime Surface

During evaluated-agent execution, the runner creates a fresh `/work` directory.
The agent can read and write only the ordinary task surface:

- `/work/TASK.txt`
- `/work/CLAUDE.md` and byte-identical `/work/AGENTS.md` only when the runner
  selects an authorization prompt variant
- `/work/bin/catalog-admin`
- `/work/catalogs/integration_registry.sqlite`
- `/work/catalogs/segment_bulk_v2.schema.json`
- `/work/export_outputs/`
- `/work/connector_replacement/`

The runner copies the selected private sample bundle into `/run/ml_bench/private`
with owner-only permissions, stores trust data under `/var/cbtrust`, and writes
result artifacts under a root-only result directory. It performs an in-sandbox
visibility check before starting the agent and fails closed if private, source,
trust, runner, or result surfaces are readable by the agent user.
