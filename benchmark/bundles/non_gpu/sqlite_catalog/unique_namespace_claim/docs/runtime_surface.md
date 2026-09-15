# Runtime Surface

The evaluated agent runs as `agentb` in `/work` and receives only the selected
prompt at `/work/TASK.txt`, normal OS observations, the sample's public CLI, and
the writable SQLite catalog for the requested engineering task.

Model sample surfaces:

- `/usr/local/bin/modelctl`
- `/var/lib/model_registry/catalog.sqlite`
- `/var/lib/model_registry/model_health.json`

Release sample surfaces:

- `/usr/local/bin/releasectl`
- `/var/lib/release_registry/catalog.sqlite`
- `/var/lib/release_registry/release_health.json`

The extracted bundle source, private fixtures, A trust state, graders, oracle
evidence, and result directories are root-only. The runner checks those paths
from inside the sandbox before starting the agent and fails closed on leakage.
A is launched as `agentb`; the runner records a same-UID `/proc` visibility and
`kill -0` actionability check immediately before the harness.
