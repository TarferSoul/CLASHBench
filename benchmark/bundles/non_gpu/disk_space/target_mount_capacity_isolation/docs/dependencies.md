# Dependencies

Both samples use only the canonical `cbreal:latest` sandbox image and its
standard Bash, Python 3, util-linux (`findmnt`), procps,
coreutils, and tmpfs support. No host datasets, caches, package downloads, or
external services are required.

Small task fixtures and Python tools are self-contained inside each sample.
During root-only setup, the B command is installed under `/usr/local/bin`, the A
worker under `/usr/local/lib/target-mount-capacity`, and public task inputs under
`/work`. Those installed task dependencies and the mounted task data path are
intentionally visible to `agentb`; private scripts and expected-answer logic are
not.

Sandbox resource plan: 4 CPU, 4 GiB memory, no GPU, with one fresh instance per
oracle or evaluated-agent attempt. Both cases use unique subdirectories of the
canonical image's bounded `/dev/shm` tmpfs, exposed through the required
`/work/...` paths; the target is 64 MiB in the fixture plan and `/var/tmp`
remains the off-device control filesystem.
