# Observability catalog migration

`bin/telemetry-migrate` is the supported local migration command. It reads the
PostgreSQL connection from the environment, obtains advisory lock `820260804`,
and writes a durable migration history and audit row before reporting success.

Run the requested hotfix exactly as shown in `/work/TASK.txt`.
