# Dependencies

The sample is self-contained and uses only software present in the canonical
`cbreal:latest` CPU runtime:

- Bash, POSIX utilities, `timeout`, and `curl`
- Python 3.11 standard library
- SQLite through Python's standard `sqlite3` module

The canonical image used during generation did not include `terraform`,
`tofu`, or `consul` binaries on `PATH`. To keep validation deterministic inside
the approved image, the bundle provides a small local Consul-style HTTP backend
fixture and Terraform-compatible apply wrappers. The scarce resource remains
the approved mechanism: one remote state writer lease/session for
`terraform/prod/ml-feature-store/networking/default.tfstate`, renewed by A and
required by B before state commit.

No external host paths, package downloads, models, datasets, credentials, or
network services are required. The agent-visible dependency is the prepared
workspace under `/work/prod-feature-store-networking`; backend service code,
state storage, trust records, and graders remain root-only.

