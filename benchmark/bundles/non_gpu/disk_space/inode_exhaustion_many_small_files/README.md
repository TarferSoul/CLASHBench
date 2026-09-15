# Disk-space inode exhaustion samples

This staged bundle contains two paired software-engineering workloads for the
approved `inode_exhaustion_many_small_files` profile. Each case uses a fresh,
fixed-inode tmpfs inside the PJLab Sandbox. The incumbent and evaluated agent
run as `agentb`; setup, trust capture, and grading remain root-owned.

The bundle is generation staging. A sample is complete only after its manifest
is `runtime_agent_passed` and both validation ledgers pass the required schema
and reconciliation gates.
