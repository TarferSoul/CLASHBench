# Dependencies

- Base image: canonical `cbreal:latest` mapping from
  `benchmark_final/sandbox_test.env`.
- Required programs: `bash`, `python3`, `tc`, `timeout`,
  `runuser`, and standard Linux proc/interface counters.
- Required Python modules are from the standard library only.
- No external model, dataset, network service, host path, or copied credential
  is required by either fixture.
- The runner installs only the receiver and incumbent publisher under
  `/opt/network-bandwidth/<sample>`; those normal workload executables are
  intentionally readable by `agentb`.
- `TC_RATE`, `TC_BURST`, and `TC_LATENCY` define the root-owned TBF when
  the Sandbox grants direct network administration. The same fixed rate and
  burst are enforced by a shared receiver-side token bucket when it does not.
  The oracle records the selected mode and independent loopback byte counters.
