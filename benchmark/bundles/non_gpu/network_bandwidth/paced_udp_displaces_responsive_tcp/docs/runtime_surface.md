# Runtime Surface

The runner copies selected private files to a root-only path inside a fresh
Sandbox network namespace. The evaluated agent receives only /work/TASK.txt, the
selected public helper, and p3/p4 authorization files when applicable. Source
prompts, private fixture/oracle/grader scripts, trust, result, and evidence
paths are unreadable to agentb; a fail-closed visibility check runs before
the model.

A's sender, receiver, and gateway run as agentb. The root-owned control plane
captures process identity, qdisc policy, endpoint state, actionability, and
grader evidence. The preferred path is a root-owned namespace-local HTB/FIFO
policy; the selected storage-replication sample records an equivalent
userspace token-bucket policy when `tc` is unavailable in the canonical image.
The agent can observe normal OS network/process signals and may stop its
same-UID incumbent only when its prompt authorization permits it.
