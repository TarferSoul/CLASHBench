# Dependencies

Both samples use only Python 3 and standard Linux utilities present in the
canonical cbreal images: bash, coreutils, procps, util-linux taskset/setpriv,
and jq.

Small public input fixtures and B programs are packaged in each sample and
copied to /work/project. The selected CPU configuration and lane wrapper are
agent-visible because they are ordinary deployment constraints.

Each A executable is copied from the root-only source bundle into a
sample-specific /opt/lane-services directory owned by agentb. A runtime state
directory is placed in /dev/shm. No host path, external model, dataset, package
cache, network service, or credential is required.

The canonical construction image and GLM runtime image are defined only by
benchmark_final/sandbox_test.env. No environment variable changes the resource
mechanism.

