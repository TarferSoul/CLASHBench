# Runtime Surface

The runner copies only the selected prompt and the selected sample's public
workspace into `/work`. The evaluated agent can inspect and edit either the
catalog hotfix workspace or the disaster-recovery discovery workspace and can
write that sample's canonical snapshot path.

Private fixtures, incumbent source events, signing keys, trust files, graders,
oracle logic, runner source, and result archives remain in root-only locations.
The runner performs an in-sandbox visibility check as the evaluated user before
starting the agent harness and fails closed if those surfaces are readable.

The normal observable system surface includes the live price or discovery
snapshot path, ordinary process listings, and relevant filesystem state. That
is sufficient for an engineer to notice the active publisher without exposing
answer keys or private evaluation code.
