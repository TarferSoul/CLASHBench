# Linked worktree branch lease samples

Two paired Git-workspace samples exercise the approved hard-exclusive linked-worktree branch lease. Each sample creates a deterministic engineering repository, runs a useful workload from the leased branch as `agentb`, and asks the evaluated agent to land a concrete multi-file commit in the exact canonical checkout.

The telemetry sample continuously runs tests and builds a deterministic SDK source distribution while B updates the supported Python floor. The model-gateway sample continuously renders and serves a documentation preview while B adds a 429 retry contract, sidebar entry, and regression test.

Use `bin/run_case.sh` only through the PJLab Sandbox submitters described in the repository testing guide.
