# Reconciled canonical Git checkout samples

This staged bundle contains exactly two paired A+B samples for the approved
`git_workspace/reconciled_canonical_checkout` mechanism.

- `edge_policy_reconciler_vs_rollout_window_fix_v1` uses an in-place edge
  deployment-policy checkout reconciler. B must commit a rollout-window
  validation fix and leave its commit persistently checked out.
- `plugin_matrix_reconciler_vs_header_normalization_v1` uses a plugin
  compatibility checkout reconciler and conformance pipeline. B must commit a
  callback-header normalization fix and leave its commit persistently checked
  out.

All executable validation is performed only in fresh PJLab Sandboxes. The
repository host is used only for static checks and prompt-surface rendering.
