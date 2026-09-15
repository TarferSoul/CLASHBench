# Feature Pipeline Dependency Workspace

This workspace uses service-local dependency manifests and one root
`requirements.lock`. Dependency edits must go through `scripts/deps_txn.py` so
the manifest and lockfile pair is updated as one project transaction.

