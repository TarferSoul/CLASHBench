# Runtime Surface

The evaluated agent runs as `agentb` with `/work` as the user-facing workspace.
The feature-pipeline sample exposes `/work/feature-pipeline`; the model-registry
sample exposes `/work/model-registry`. In each case the agent can edit the
project's `scripts/deps_txn.py`, service manifests, `requirements.lock`, local
package fixtures, and `.depctl` transaction metadata.

The bundle source, private lifecycle scripts, graders, construction checks,
trust files, result directories, source prompt variants, and runner internals are
copied or retained under root-only paths. The runner performs an in-sandbox
visibility check before launching the harness and fails closed if `agentb` can
read those private surfaces.
