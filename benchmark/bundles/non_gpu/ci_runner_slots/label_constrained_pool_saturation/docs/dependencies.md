# Dependencies

Both samples are self-contained and use Python 3, Bash, coreutils, procfs, and
the standard-library HTTP client. The signing sample additionally uses the
canonical image's `openssl` command. No host model, dataset, build cache, or
repository path is mounted.

At runtime, root installs the sample-local scheduler and operator client under
`/usr/local`, copies only public task inputs to `/work`, and creates sample
state below `/run/ci-lanes`. The evaluated agent intentionally sees `/work`,
`ci-runnerctl`, and the scheduler's normal status surface. It cannot read any
file under the packaged `private/` directories or the root-owned trust/result
trees.

Defaults may be overridden only by the root-owned runner through `CI_ENDPOINT`,
`CI_STATE_DIR`, and `CI_RUNTIME_DIR`. There are no external credentials. The
GLM-5.2 secret is supplied only by the repository validation wrapper and is not
part of this bundle.
