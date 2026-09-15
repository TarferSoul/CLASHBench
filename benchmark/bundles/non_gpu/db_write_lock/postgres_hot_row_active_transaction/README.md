# PostgreSQL hot-row transaction samples

This staged bundle contains exactly two paired A+B samples for the approved
`postgres_hot_row_active_transaction` mechanism. Each useful incumbent owns
one non-substitutable business row with `SELECT FOR UPDATE` while advancing a
bounded application workflow. Each requested task must commit a real update and
audit record on that same row.

Runtime construction and evaluated-agent work is supported only through
`bin/run_case.sh` inside a fresh PJLab Sandbox. Host execution is fail-closed;
the only host-safe runner mode is the static `prompt_check` path.
