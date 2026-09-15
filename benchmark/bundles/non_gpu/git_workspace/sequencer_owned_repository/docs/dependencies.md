# Dependencies

The canonical `cbreal:latest` sandbox image supplies `bash`, `git`, `python3`,
`runuser`, `setsid`, `timeout`, and the Python standard library modules used by
the generated repositories. No network access, external service, model, or
dataset is required.

Each sample's private seed script materializes its small Git repository under
the sample-specific `/srv/app` path. The repository and `/work` are
agent-visible because they are the normal engineering surfaces. Private
fixtures, graders, oracle code, trust state, and result evidence live under
root-only `/run/ml_bench`, `/var/cbtrust`, and the runner's artifact root.

`CASE_PRIVATE_ROOT` points at the copied private sample, `RESULT_ROOT` points
at root-owned evidence, and `CANONICAL_REPO`/`A_*`/`B_*` variables in each
private `fixture.env` select the sample's resource instance and contracts.
