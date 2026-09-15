# Nginx shared-zone schema collision samples

This staged bundle contains two independent state-integrity samples for the
approved `shared_zone_name_and_schema_collision` mechanism. Each incumbent is a
normal nginx-backed engineering service; the requested deployment supplies a
different schema under the same mandatory shared-zone name.

The bundle is self-contained under `samples/`. Runtime execution is only valid
through the PJLab Sandbox runner in `bin/run_case.sh`.
