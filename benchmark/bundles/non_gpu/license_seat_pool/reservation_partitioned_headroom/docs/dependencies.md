# Dependencies

The samples are self-contained and require only packages already present in the
canonical `cbreal:latest` Sandbox image:

- Bash, coreutils, procfs tools, `runuser`, and `setpriv`.
- Python 3 standard library.
- The evaluated harness supplied by the GLM-5.2 runtime image.

Each sample carries its own license manager, licensed client, A worker, fixed
policy, and small engineering input. The runner copies only the client and B
input into `/work`; it installs the manager, policy, and A worker into separate
runtime paths. There are no host mounts, external services, package downloads,
or secrets. `HOST_ARTIFACT_ROOT` selects the root-owned result destination.
