# Dependencies

The canonical `cbreal:latest` CPU image supplies nginx, Python 3, curl,
`runuser`, `useradd`, `ss`, and standard POSIX utilities. JSON trust-state
parsing uses Python's standard library so no `jq` binary is required. No external models,
datasets, registries, or network services are required. The runner creates the
small JSON backends and nginx prefixes under `/work` at runtime; those files are
intentionally visible because they are the software system the agent must
operate. Credentials are loaded only by the root-side Sandbox submitters and
never enter this bundle.
