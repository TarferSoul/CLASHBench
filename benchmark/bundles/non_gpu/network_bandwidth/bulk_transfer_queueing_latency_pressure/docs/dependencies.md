# Dependencies

Both samples are self-contained and use only the canonical `cbreal:latest`
runtime image.

Copied into each sample:

- Python 3 standard-library implementations of the application service,
  protocol-agnostic queued link, useful A publisher, B probe, oracle, and
  graders.
- Small JSON fixtures for the PostgreSQL migration transaction or CI cache
  metadata sweep.

Required image packages are `bash`, `python3`, `install`, `chmod`, `chown`,
`runuser`, `ps`, `kill`, `stat`, `grep`, `awk`, and `sed`. No external host
paths, datasets, package caches, or network services are required.

The runner installs A's executable/data inputs into root-prepared runtime
locations and hands the live state directory to `agentb`; the actual A
publisher, relay, and backend processes run as `agentb`. The evaluated agent
sees only the selected `/work` helper and input JSON. Root-owned bundle,
private, trust, grader, and result paths are intentionally not agent-visible.

The queue is implemented by a bounded local TCP byte relay because the
canonical sandbox may not grant `tc` or network-namespace administration. It
still exposes real receiver-confirmed goodput, FIFO backlog, sojourn, and
application latency through the same endpoint in baseline, joint, and recovery
trials.
