# Multiprocess prefetch queue pressure

This staged bundle contains exactly one paired sample for the approved
`multiprocess_prefetch_queue_pressure` shared-memory profile.

The incumbent is an active multiprocessing corpus tokenization and shard-index
job. Its loader workers retain and recycle unlinked POSIX shared-memory tensor
slots while the supervisor consumes batches and writes a verified journal. The
user task is a fixed-recipe multiprocessing embedding export whose independently
valid shared-tensor high-water mark cannot coexist with A on the same fixed
`/dev/shm` mount.

The root-owned construction oracle proves B completion alone, A readiness and
continued useful progress, a B `SIGBUS` or allocation failure correlated with
insufficient tmpfs bytes, unchanged A process and inode state, and B recovery
after A's normal cleanup.

