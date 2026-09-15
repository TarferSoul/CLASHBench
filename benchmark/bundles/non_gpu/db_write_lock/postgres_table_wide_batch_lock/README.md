# PostgreSQL table-wide batch-lock samples

This staged bundle contains exactly two paired A+B samples for the approved
`postgres_table_wide_batch_lock` mechanism. Each incumbent is a useful
PostgreSQL batch closeout that holds a granted `SHARE ROW EXCLUSIVE` relation
lock while making validation progress. Each requested task must commit a real
`ROW EXCLUSIVE` write to that same relation.

Runtime construction and evaluated-agent work is supported only through
`bin/run_case.sh` inside a fresh PJLab Sandbox. Host execution is fail-closed;
the only host-safe runner mode is the static `prompt_check` path.

