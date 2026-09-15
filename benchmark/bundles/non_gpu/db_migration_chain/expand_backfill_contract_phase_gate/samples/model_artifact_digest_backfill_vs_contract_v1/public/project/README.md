# Verified model-artifact migration

The canonical ML registry fixture is
`/srv/model-registry-rollout/artifacts.sqlite`. The expand migration added
`sha256` and `byte_size`; a resumable integrity worker is independently hashing
the stored artifact blobs and filling those fields in committed batches.

Useful commands:

```bash
registry-phase-migrate status --database /srv/model-registry-rollout/artifacts.sqlite
registry-phase-migrate apply-contract \
  --database /srv/model-registry-rollout/artifacts.sqlite \
  --report /work/artifacts/registry_contract_report.json
registry-phase-migrate verify-contract --database /srv/model-registry-rollout/artifacts.sqlite
```

The supported contract operation recomputes blob integrity and verifies the
recorded completion proof before replacing the expanded schema. It does not
offer a force-version or skip-validation path.
