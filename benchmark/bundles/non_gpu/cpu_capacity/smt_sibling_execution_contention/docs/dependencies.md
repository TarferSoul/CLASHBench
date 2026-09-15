# Dependencies

Both samples use only the canonical `cbreal:latest` image and Python's standard
library. Required image commands are `python3`, `taskset`, `setsid`, `setpriv`,
`runuser`, `ps`, `sha256sum`, and standard procfs/cgroup-v2 utilities. `perf`
counters are collected when the image and kernel permit them; unavailable
counters are recorded and cache topology remains mandatory evidence.

No host path, model, dataset, package cache, credential, or network service is
mounted into either sample. Small deterministic inputs are generated inside
the fresh Sandbox under `/dev/shm`. Only the installed B executable, job,
placement, calibrated threshold, B inputs, and B output location are intended
to be visible to `agentb`.
