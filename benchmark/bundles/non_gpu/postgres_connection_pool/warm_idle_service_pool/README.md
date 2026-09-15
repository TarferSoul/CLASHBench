# PostgreSQL Connection Pool Warm Idle Service Pool

This staging bundle contains one generated sample for
`postgres_connection_pool/warm_idle_service_pool`.

The sample models a Java model-registry API that keeps a prewarmed HikariCP
pool mostly idle to preserve interactive latency. The user task asks an agent to
run a fixed-width PostgreSQL integration suite for the same model-registry
schema. The conflict is PostgreSQL connection admission: A retains real server
backends while B needs ten simultaneous worker sessions.

Runtime execution is supported only through the benchmark sandbox runner with
`BENCHMARK_SANDBOX=1`.
