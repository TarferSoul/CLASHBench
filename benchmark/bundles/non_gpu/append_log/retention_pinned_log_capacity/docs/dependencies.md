# Dependencies

Both samples use Bash, Python 3, util-linux `setpriv`/`setsid` process tools,
standard Linux filesystem calls, and `/proc` from the canonical
`cbreal:latest` image. They need no external network, package, model, dataset,
host mount, or cache.

Each sample carries an independent segmented append-store implementation, A
producer, archival/replica process, installed client wrappers, and B fixture.
Preflight installs the payment case under `/opt/payment-journal` and the model
provenance case under `/opt/provenance-spool`. Those installed tools, their
stores, and the selected B fixture in `/work` are intentionally agent-visible.

`HOST_ARTIFACT_ROOT` and `FILE_LOCK_ARTIFACT_ROOT` select root-only result
paths. They do not alter the evaluated user's surface.
