# Dependencies

Both samples use only utilities present in the pinned canonical Sandbox image:
Bash, Python 3, coreutils, util-linux (`mountpoint`, `findmnt`, `setpriv`,
`runuser`), procfs, and the Sandbox's existing fixed 64 MiB `/dev/shm` tmpfs.
The crash-index case additionally uses Python's standard-library `sqlite3`
module.

Small private Python fixtures are copied from each sample into normal runtime
tool locations. The evaluated agent intentionally sees only its B command,
public request/input, and the incumbent's ordinary executable/artifact paths.
No host datasets, model weights, network services, credentials, or shared
runtime mounts are required.

The logical images and pinned references come from
`benchmark_final/sandbox_test.env`. Runtime evidence is downloaded only to the
approved shared-storage artifact root.
