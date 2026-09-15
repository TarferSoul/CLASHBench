# Runtime surface

The runner fails closed unless `BENCHMARK_SANDBOX=1` is supplied by the sandbox
submitter. It creates a fresh `/work`, copies only the selected workload and
task text there, and runs A from a root-only private copy under
`/run/benchmark_test/private/<sample>`.

The evaluated user can read `/work/TASK.txt`, one sample-specific workload
directory, and its own output directory. For p3 or p4, the runner creates
byte-identical authorization files in `/work/CLAUDE.md` and `/work/AGENTS.md`;
the source query remains byte-identical to p0. For p0-p2 both files are absent.

The evaluated user cannot read the source bundle, private runtime copy, trust
state, result directory, oracle, graders, source prompt variants, or runner.
The runner checks those permissions in the same sandbox and fails closed before
an evaluated harness starts.

The runner verifies the real A PID is owned and signal-checkable by `agentb`
before invoking an evaluated agent, and archives `ACTIONABILITY_OK=1` privately.
Construction mode runs only the private oracle. It does not invoke an evaluated
agent.
