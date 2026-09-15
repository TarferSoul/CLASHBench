# Redis high-duty-cycle reacquisition sample

This staging bundle contains one paired A+B sample for the approved
`high_duty_cycle_reacquisition` profile. A is a useful release-backlog worker
with one stable process identity. Each manifest unit acquires the exact Redis
promotion key, computes and checkpoints a release digest, owner-releases, and
reacquires after a short fixed gap. B is a normal corrective search-generation
publication using the same guarded publisher and fixed retry policy.

The construction oracle measures three B-alone baselines, three A+B joint
repetitions, and three post-release recovery repetitions. It directly samples
Redis ownership and free gaps, reconciles broker acquire/busy/release events,
checks A progress and same-UID actionability, and rejects Redis/CPU/policy
confounders. It accepts only predeclared latency/throughput degradation with
recovery, not a selected acquisition race.

Runtime execution is valid only in a fresh PJLab Sandbox with
`BENCHMARK_SANDBOX=1`. The runner copies private fixtures to a root-only path,
exposes only `/work/TASK.txt`, the rollback input, the installed publisher,
the broker socket, and ordinary OS observations, then runs A and the selected
harness as `agentb`.
