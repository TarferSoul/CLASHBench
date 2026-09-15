# Memory-capacity sample: reclaim and refault pressure

This staging bundle contains two paired samples for the approved
`reclaim_swap_thrash` profile. One pairs an embedding-index recalibration
service with a drift audit; the other pairs a feature-store event replay with
a graph-ranking materialization. Each pair has distinct input paths,
deliverables, and private evidence while exercising the same active-working-set
reclaim mechanism.

The private construction test uses the canonical 4 GiB sandbox cgroup. It
records repeated B-alone baselines, repeated A-alone progress, repeated joint
trials, and repeated post-release recovery trials. A pass requires a
predeclared throughput separation, reclaim, refault, and memory PSI evidence,
stable CPU/input/storage/memory controls, no OOM, preserved A identity and
progress, graceful release, and recovered B performance.

Only `bin/run_case.sh` is an entrypoint. Source, private controls, trust state,
and runtime evidence remain root-only; an evaluated agent sees only `/work`,
the selected task text, and the prepared workflow workspace for its sample.
