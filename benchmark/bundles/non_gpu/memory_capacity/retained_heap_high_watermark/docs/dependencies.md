# Dependencies

Both samples use only Python 3 standard-library modules supplied by the pinned
`cbreal:latest` image. The code-index sample uses AST parsing, HTTP utilities,
and a local repository fixture. The feature-cache sample uses HTTP utilities
and deterministic local binary tensor fixtures.

No host model, dataset, cache, package environment, credential, or external
service is mounted into either sample. Runtime paths under `/opt`, `/run`,
`/var/lib`, and `/var/cbtrust` are created inside each fresh Sandbox.

Only the task project under `/work` is intentionally agent-visible. A's
temporary startup copy is readable by `agentb` only long enough to load the
service; the runner seals that copy after warm-up. Root-owned private source,
expected values, trust state, and result evidence are not visible.

Per-sample Sandbox limits are declared in each manifest: 4 CPU and 4 GiB for
the code-index sample, and 4 CPU and 6 GiB for the feature-cache sample.
