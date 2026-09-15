# Dependencies

- The canonical `cbreal:latest` images supply Bash, Python 3, SHA-256, HTTP
  sockets, `runuser`, `/proc`, and standard POSIX tools.
- No external model, dataset, package manager, or internet service is needed;
  each sample deterministically builds its own payload fixtures.
- The package sample exposes only its fetch utility, request JSON, and gateway
  endpoint. The model sample exposes its snapshot fetch utility, request JSON,
  and artifact endpoint.
- Private fixture scripts, gateway counters, A trust, graders, oracle output,
  and result archives remain root-only. A's cache/progress files are owned by
  `agentb` so the same-UID actionability contract is real.
- The canonical image lacks the namespace and `CAP_NET_ADMIN` features needed
  for kernel `tc` shaping. Each gateway therefore implements the same finite
  directional ingress budget in user space while recording scheduled,
  delivered, queued, and application-processing evidence.
