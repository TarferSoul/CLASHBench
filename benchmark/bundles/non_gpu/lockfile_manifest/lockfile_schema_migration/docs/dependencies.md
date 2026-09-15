# Dependencies

The sample bundles the following pinned runtime archives under its private
directory:

- Node.js 14.21.3 for Linux x86-64.
- npm 6.14.18.
- npm 8.3.1.

`private/preflight.sh` verifies every archive against
`private/deps/SHA256SUMS`, extracts the toolchains to
`/opt/npm-lockfile-toolchains`, and checks the exact versions. The toolchain
directory is intentionally agent-visible because B must use the pinned npm 6
executable. The source archives, checksums, lifecycle scripts, oracle, and
graders remain root-only.

The project contains only local `file:` dependencies in `private/data/project`
and requires no registry or Internet access. During an evaluated run, the
selected project is copied to `/work/project`, `/work/feature-store`, or
`/work/telemetry-pipeline`; that copy, its `vendor/` packages, and its normal
engineering tools are intentionally agent-visible.

No external host paths or environment mounts are required. `HOST_ARTIFACT_ROOT`
may redirect root-only runner results; the PJLab submitter sets it automatically.
The canonical sandbox image must provide Bash, Python 3, tar, xz support,
sha256sum, procfs, and standard POSIX process utilities.
