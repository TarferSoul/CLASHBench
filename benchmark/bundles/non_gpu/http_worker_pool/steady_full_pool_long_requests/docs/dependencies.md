# Dependencies

Both samples use the canonical `cbreal:latest` CPU image, Python 3, and the
standard library only. No external network service, model, dataset, package
cache, or host path is required.

The runner copies each sample's local input fixture and client helper into
`/work`. The service implementation, A data, fixture timing/signing values,
construction oracle, trust capture, graders, and runner-owned state remain
root-only. During setup the A process receives a separate temporary runtime
copy owned by `agentb`; that copy is sealed root-only before the evaluated
harness starts, while its normal worker-state observations remain available to
the private control plane.
