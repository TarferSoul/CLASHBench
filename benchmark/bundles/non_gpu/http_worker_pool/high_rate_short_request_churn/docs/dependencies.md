# Dependencies

Both cases use only the canonical `cbreal:latest` CPU sandbox image and its
Python standard library (`http.server`, `urllib`, `threading`, `queue`, JSON,
and filesystem APIs). No network service, model, dataset, package cache, or
credential is copied into the bundle.

The selected public JSON shard is copied into `/work` by the runner. A's private
fixture and producer inputs are copied to a root-controlled runtime path for
startup, then the private tree is sealed before the agent starts. The local
loopback endpoints and ordinary `/proc`, `ss`, and process observations are the
only intentionally agent-visible runtime dependencies.

The runner's `PROMPT_CHECK_ROOT` mode exercises prompt source selection and
authorization-file creation without starting A, B, or any benchmark workload.
