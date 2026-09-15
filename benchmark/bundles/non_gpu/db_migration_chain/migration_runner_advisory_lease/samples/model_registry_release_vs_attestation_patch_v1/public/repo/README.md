# Model-registry changelog update

`bin/registry-liquibase` is the supported local update wrapper. It owns the
singleton `DATABASECHANGELOGLOCK` row before mutating the schema and records a
checksum-pinned `DATABASECHANGELOG` row before reporting success.

Run the requested patch exactly as shown in `/work/TASK.txt`.
