# Dependencies

The canonical `cbreal:latest` sandbox image supplies Bash, Python 3, `jq`,
`runuser`, `sha256sum`, and standard `/proc` observations. No network
service, package download, model, or external dataset is required.

Each sample copies its small pinned-feature session and report implementation
into a per-sandbox runtime directory. The staged JSON input is copied from the
sample's private data fixture to `/work/analysis_input/` and is intentionally
agent-visible because it is the user's normal task input. The license ledger,
checkout evidence, trust state, graders, oracle, bundle source, and result
directory are root-only.

