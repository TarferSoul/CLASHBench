# Dependencies

The sample uses Python 3 and its standard-library `sqlite3` module, plus normal
Linux utilities from the canonical `cbreal:latest` image (`bash`, `runuser`,
`ps`, `stat`, and `kill`). No external network, model, or dataset dependency is
required.

At runtime the root-owned setup installs the sample-local `catalogctl.py` as
`/usr/local/bin/catalogctl` and the route service as
`/opt/inference-route-service/route_gateway.py`. The SQLite catalog and its
request/health fixtures live under `/var/lib/inference_catalog`; these are
intentionally writable by `agentb`. The source bundle, copied private fixture,
trust state, graders, oracle, and result evidence remain unreadable to the
evaluated agent.
