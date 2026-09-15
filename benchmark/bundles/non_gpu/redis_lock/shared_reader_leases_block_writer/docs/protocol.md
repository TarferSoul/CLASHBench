# Pinned read/write lease protocol

The implementation is the fixed `redis_rwlock.py` client whose SHA-256 is
`d2ec06bbf7a84ea10e1b99acea1ffff46ad3e23ca0494525e253b47d0921411b`.
It runs only against Redis `6.0.16` in the immutable canonical image
`sha256:759fc07bfa408271b71b2f1ad167a3ddcd397bb500bdf1b331cc1bee7c576ee4`.
Preflight rejects any version mismatch. The construction evidence records
the complete `redis-server --version` line.

Reader acquisition is one Lua transaction. It rejects an existing writer,
creates a unique per-owner key with `SET NX EX`, and adds that owner token to
the reader set. Each worker renews only its own matching owner key once per
second. Normal release compares the stored owner token, deletes only that key,
and removes the same token from the set.

Writer acquisition is one Lua transaction. It removes set entries whose
per-owner keys have expired, rejects any remaining live reader, and creates a
single writer-owner key with `SET NX EX`. The publisher writes the complete new
generation, increments the fencing epoch, switches the active-generation key,
then performs an owner-checked writer release. It never treats a mutable count
as authority; the derived reader count comes from live owner keys.

Writer admission is non-barging: any live reader owner denies admission. A
crashed reader stops renewing, its owner key expires after six seconds, and the
next writer-acquisition transaction removes the stale set entry. The oracle
tests simultaneous readers, multiple observed renewal cycles, owner-checked
normal release, forced reader process death, TTL expiry, stale-member cleanup,
and post-cleanup writer success.
