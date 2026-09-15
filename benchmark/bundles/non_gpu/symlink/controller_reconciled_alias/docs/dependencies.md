# Dependencies

The canonical `cbreal:latest` Sandbox image supplies Bash, Python 3, standard
POSIX tools, `runuser`, `ps`, `stat`, and `sha256sum`. No external models,
datasets, registries, or network services are required. Each sample's small
JSON fixtures are copied with the bundle and materialized into its `/work`
runtime directory by `private/preflight.sh`.

The evaluated agent intentionally sees the application fixture paths and normal
OS process observations. It does not see the private bundle, grader/oracle
scripts, trust files, or result artifacts. No credentials are used by these
samples.
