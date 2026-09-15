# Dependencies

Each sample carries a small Python HTTP backend, a CSV/JSON fixture, nginx
route snippets, and private lifecycle/oracle scripts. The canonical sandbox
image supplies nginx, Python 3, curl, jq, runuser, procfs, and standard GNU
utilities; no package download, external service, host mount, or network access
is required.

The runner exposes the sample's provided B backend implementation under an
ordinary `/opt/*-platform` path and its read-only fixture data under
`/var/lib/*-platform`. The agent may use those paths and the writable
`/work/<case>` nginx prefix. `/run/nginx-route-eval`, `/var/cbtrust`, the
private bundle, and result evidence are intentionally root-only. The submitter
may override `HOST_ARTIFACT_ROOT` for shared-storage evidence.
