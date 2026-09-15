# Dependencies

Both samples require only the canonical `cbreal:latest` Sandbox image and its
standard Python 3, Bash, util-linux, procfs, and coreutils tools. No external
datasets, model weights, package downloads, mounts, or network services are
required.

The evaluated-agent stage uses the canonical root-only OpenCode runtime image
selected by `benchmark_final/sandbox_test.env` and the GLM-5.2 validation
wrapper.

