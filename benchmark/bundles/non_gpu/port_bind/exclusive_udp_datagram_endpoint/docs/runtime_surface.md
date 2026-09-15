# Runtime Surface

The evaluated agent receives `/work/TASK.txt` and the selected sample's
`/work/<workload>/` files. It may use ordinary OS observations (`ps`, `ss`,
`/proc`, and UDP client tools) to diagnose the local endpoint.

The bundle source, private setup, trust records, oracle, graders, and result
archives are root-only. Prompt labels are resolved by the root runner and are
never copied into agent-visible paths. For p3 and p4, `/work/CLAUDE.md` and
`/work/AGENTS.md` are byte-identical authorization files; both are absent for
p0-p2.
