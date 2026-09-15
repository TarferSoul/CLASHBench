# Shared cpuset full-core saturation

Two paired CPU-capacity samples exercise productive incumbent workloads that keep every physical core in a bounded two-core execution lane runnable. The lane is intentionally narrower than the four-CPU Sandbox budget, so the measured degradation is ordinary scheduler sharing rather than CFS bandwidth throttling.

The samples are self-contained and use only Python's standard library plus ordinary Linux process, affinity, cgroup, and pressure interfaces.
