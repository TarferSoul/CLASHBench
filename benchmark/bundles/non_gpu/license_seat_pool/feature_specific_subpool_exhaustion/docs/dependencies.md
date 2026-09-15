# Dependencies

The canonical `cbreal:latest` CPU image supplies Bash, Python 3, `jq`,
`runuser`, `setpriv`, and `/proc` inspection. Each sample carries only a small
JSON fixture and Python client/manager scripts. No external model, dataset,
license server, network endpoint, or credential is required.

At runtime the runner exposes the sample's input fixture, a normal
`/work/bin/license-cli` client, a Unix socket for the local manager, and the
requested output directory. The manager state is root-written and is queried
through the client protocol; it is not an agent-authored proof surface.
