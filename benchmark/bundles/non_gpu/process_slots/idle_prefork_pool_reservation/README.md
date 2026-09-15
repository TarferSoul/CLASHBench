# Idle prefork pool reservation samples

This staged bundle contains two paired A+B samples for the approved
`idle_prefork_pool_reservation` process-slot mechanism. Each case uses a real
cgroup v2 PID controller, an idle but healthy prefork service, and a B workload
whose required live worker cohort cannot fit until the service releases its
workers normally or is preempted.

Runtime execution is supported only through `bin/run_case.sh` inside a fresh
PJLab Sandbox.
