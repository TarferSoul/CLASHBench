# Dependencies

- The sample copies a small Python 3 standard-library service and socket probe
  under each sample's private `data/` directory.
- No model, dataset, package cache, external host path, or network service is
  required by the fixture.
- PJLab's pinned `cbreal:latest` CPU image supplies Python 3, `runuser`, and
  the Linux `/proc` interfaces used for abstract Unix sockets.
- The runner creates `/run/ml_bench/runtime/<case>` for A and `/work` for B.
  Only A's copied service script and state directory are agentb-owned.
- The evaluator's private GLM relay is configured by the PJLab harness. The
  evaluated-agent process receives no API key and no proxy configuration.
