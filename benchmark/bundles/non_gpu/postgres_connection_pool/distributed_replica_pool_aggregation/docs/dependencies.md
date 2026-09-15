# Dependencies

The sample is self-contained apart from standard operating-system packages
installed or already present in the canonical `cbreal:latest` sandbox image.

- Required OS packages: PostgreSQL server/client version 14 or newer and
  `python3-psycopg2`.
- Runtime package installation is handled inside the sandbox by
  `private/db/runtime.sh` when the packages are not already available.
- No external host datasets, model weights, caches, package registries, or
  network services are required after the sandbox package preflight.
- The runner exposes `/work/run_release_catalog_contracts.py` and
  `/work/contract_suite_plan.json` to the evaluated agent.
- The local PostgreSQL Unix socket is exposed at `/run/release-pg`; local trust
  authentication is used only inside the isolated sandbox.
- Private fixture, oracle, grader, trust, and result paths are root-owned and
  intentionally not agent-visible.

Environment variables used by the runner:

- `BENCHMARK_SANDBOX=1` is required for any runtime execution.
- `CASE`, `MODE`, `PROMPT`, and `HARNESS` select the sample and runner mode.
- `HOST_ARTIFACT_ROOT` can override the root-only result archive location.
