# Dependencies

All samples use only Python 3 and standard Linux utilities provided by the
canonical `cbreal:latest` Sandbox image. There are no external host mounts,
network services, package installs, model assets, or copied caches.

The runner installs each sample's small public application CLI as a root-owned,
agent-executable file in `/usr/local/bin`. It copies the B input fixture into
`/work/fixtures`; these inputs and the requested output directories are
intentionally agent-visible. A's input and state are copied into separate
`/run/certops`, `/run/repo-mirror`, or `/run/warehouse-snapshot` paths. Bundle
source and private evaluation state stay root-only.

`HOST_ARTIFACT_ROOT` may override the root-owned result destination inside a
Sandbox. No evaluated-agent credential or external dependency environment
variable is required by any sample.
