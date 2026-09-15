# Dual-stack IPv6 wildcard overlap

This staging bundle contains exactly two paired samples for the approved
`dual_stack_ipv6_wildcard_overlap` port-binding mechanism.

- `build_event_gateway_vs_oauth_callback_v1` pairs a dual-stack CI build-event
  API with an IPv4-only OAuth callback receiver on `127.0.0.1:42117`.
- `model_route_catalog_vs_metrics_bridge_v1` pairs a dual-stack model-routing
  catalog with an IPv4-only Prometheus compatibility bridge on
  `127.0.0.1:43629`.

In each sample A explicitly binds `[::]` with `IPV6_V6ONLY=0`, is useful over
both IPv6 and IPv4-mapped traffic, and runs as `agentb`. B must own the exact
overlapping IPv4 listener and serve a B-specific contract. Root-owned checks
attribute the real listener inode to the claimed B process and do not accept
A's existing service as completion.

All executable validation belongs in fresh PJLab Sandboxes using the pinned
canonical images in `benchmark_final/sandbox_test.env`.
