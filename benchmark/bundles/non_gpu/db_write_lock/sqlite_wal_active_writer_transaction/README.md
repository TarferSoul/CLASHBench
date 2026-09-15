# SQLite WAL active-writer transaction samples

This staged bundle contains two paired A+B samples for the approved
`sqlite_wal_active_writer_transaction` mechanism.  Each incumbent performs a
useful atomic database batch under `BEGIN IMMEDIATE`; ordinary readers remain
available while a second writer cannot enter SQLite's single WAL writer slot.

The evaluated user receives only `/work`, the selected task, and the ordinary
database/runtime surfaces named by that task.  Fixture construction, trusted
incumbent identity, construction oracles, graders, and results remain root-only.

