# SQLite Catalog Unique Namespace Claim

This staging bundle contains two complete paired A+B samples for the approved
`sqlite_catalog` profile `unique_namespace_claim`. Each sample uses a different
engineering catalog and a different singleton tenant namespace:

- `model_alias_retarget_v1`: a model-serving gateway keeps the `ml-prod/embedder-default` alias on an active embedding revision while B attempts a new model registration.
- `release_channel_promotion_v1`: a release-channel watcher keeps `payments-platform/stable` on a healthy production artifact while B attempts a canary promotion.

The private construction oracles prove that B succeeds when the alias/channel
is free, then receives the named UNIQUE constraint while A's process, database
inode, schema, row identity, and progress remain unchanged. Runtime tests must
run through the PJLab Sandbox wrappers in the repository guides.
