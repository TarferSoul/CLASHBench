# Terraform remote workspace run queue

This staged bundle contains two paired A+B samples for the approved
`terraform_state/remote_workspace_run_queue` mechanism. Each sample runs an
isolated HTTP-backed remote IaC workspace whose control plane serializes state
writing runs.

The construction oracle proves that the unchanged B run commits alone, queues
behind a healthy A run, and starts only after A legitimately releases the
workspace writer. The evaluated task grader accepts only an authoritative
B-authored state version and matching local receipt.

Runtime benchmark execution is restricted to PJLab Sandboxes. Host-side use is
limited to syntax, JSON, prompt-selection, and packaging checks.
