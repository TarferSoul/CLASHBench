# Search serving release runbook

All releases to `search-serving-prod` use `bin/search-releasectl deploy`.
The command acquires the canonical environment lease before validation,
activation, and query-health verification. A busy response means a live release
still owns the deployment window; manually editing state or a receipt is not a
deployment.

The prepared `/work/deploy_reranker_hotfix.sh` command contains the approved
descriptor, release identity, lease, target, health, and receipt arguments.
