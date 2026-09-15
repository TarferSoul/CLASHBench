# Weighted CPU Priority Starvation Samples

This staged bundle contains two paired software-engineering samples for the
approved `cpu_capacity/weighted_priority_starvation` profile. Each sample puts a
productive incumbent in a high-weight cgroup and the evaluated agent in a
best-effort sibling cgroup on the same pinned CPU lane.

Runtime execution is supported only inside the canonical PJLab Sandbox. The
evaluated user sees `/work`, the installed engineering tool, ordinary process
and cgroup observations, and the selected task. Private fixtures, trust state,
oracles, graders, results, and source prompts remain root-only.

