# Dependencies

Both samples use only tools in the canonical CPU Sandbox image: Bash, Python 3,
`runuser`, standard `/proc` files, and Python's standard-library `fcntl`
interface. No host path, network service, package download, model, or dataset is
required.

Each sample privately packages its own release client/controller and small JSON
release descriptors. Preflight copies the normal client, the B descriptor, and
operations documentation into `/work`; those copied inputs are intentionally
agent-visible. A's descriptor, root trust files, construction logic, observers,
and graders are never copied to the agent surface.

Runtime locations are selected by each sample's `private/fixture.env`. The
runner honors `HOST_ARTIFACT_ROOT` supplied by the Sandbox submitter for
root-only result collection.
