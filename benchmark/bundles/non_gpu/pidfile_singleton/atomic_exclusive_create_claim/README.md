# Atomic exclusive-create pidfile samples

This staging bundle contains three paired A+B samples for the approved
`pidfile_singleton/atomic_exclusive_create_claim` profile. Each incumbent uses
the same application entrypoint exposed to B and wins its canonical pidfile
with `O_CREAT|O_EXCL`. The pidfile pathname and inode remain owned for the
entire useful workload lifetime.

The resumed work added one distinct data-engineering sample,
`warehouse_snapshot_dispatcher_vs_partition_ledger_v1`: A is a feature-store
partition dispatcher and B is a model-observability snapshot replay. It uses a
different canonical pathname, input schema, progress chain, and output
contract, while preserving the same atomic admission mechanism.

The private construction oracle proves B-alone success, A identity and useful
progress, an `EEXIST` admission failure with A present, unchanged pidfile
identity, absence of a second coordinator, continued A progress, normal release,
and B-after-release success. Evaluated-agent runs additionally use a root-owned
observer to witness a real B process owning the canonical pidfile inode.
