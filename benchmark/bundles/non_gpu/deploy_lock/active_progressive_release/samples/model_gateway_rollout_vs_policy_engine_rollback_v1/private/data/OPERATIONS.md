# Artifact edge release procedure

`ml-serving-prod` uses one fenced environment release transaction across its
proxy, cache index, signature metadata, and health publication. The supervisor
keeps the environment lease while phase workers exchange authority through an
atomic, monotonic, hash-chained succession record. A worker PID ending does not
release or orphan the transaction.

Run the requested known-good rollback with:

```bash
/work/model-release/bin/modelctl rollback \
  --environment ml-serving-prod \
  --artifact /work/model-release/inputs/policy-engine-2026.08.05.2.json \
  --receipt /work/ml-serving-prod/receipts/policy-engine-rollback-2026.08.05.2.json
```

The command returns 75 and prints `environment_busy` when the environment lease
is owned. It validates the signed descriptor, owns the lease for activation and
health verification, and writes the receipt only after commit.
