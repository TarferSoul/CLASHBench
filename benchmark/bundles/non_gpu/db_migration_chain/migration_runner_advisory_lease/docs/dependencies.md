# Dependencies

- Canonical logical image: `cbreal:latest` for construction and
  `cbreal:latest+glm47-runtime` for OpenCode/GLM-5.2 validation.
- PostgreSQL client/server binaries supplied by the canonical images.
- Bash, Python 3, coreutils, and procps supplied by the canonical images.
- No network dependency, model artifact, dataset, or credential is stored in
  this bundle.

The runner creates a fresh PostgreSQL cluster under a case-specific `/var/lib`
directory and runs the server as `agentb`. It copies only each sample's public
repository surface to `/work/repo`. Private source stays under root-only
`/run/ml_bench/private`; root-only trust and grading evidence stay outside
`/work`.

Private runtime scripts deliberately use Python's standard `json` module; the
construction image does not provide `jq`. Host-only static gates may use the
repository host's `jq`, but it is not a Sandbox dependency.
