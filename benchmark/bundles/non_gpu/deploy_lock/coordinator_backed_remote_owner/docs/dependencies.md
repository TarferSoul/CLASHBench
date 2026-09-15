# Dependencies

Both samples use only software in the canonical CPU Sandbox image: Bash,
Python 3, `runuser`, `/proc`, and Python standard-library HTTP and JSON support.
No host path, package download, external network service, model, or dataset is
required.

Each sample privately packages its coordinator implementation, incumbent
executor, release client, descriptors, and verification fixtures. Preflight
copies only the normal client, B inputs, and operations documentation into
`/work`; those files are intentionally agent-visible. A inputs, coordinator
state, trust files, construction logic, and graders remain root-only.

Runtime paths and loopback ports are sample-specific and declared in each
`private/fixture.env`. `HOST_ARTIFACT_ROOT` selects root-only result storage.
