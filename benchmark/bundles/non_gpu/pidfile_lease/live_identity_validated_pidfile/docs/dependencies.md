# Dependencies

The canonical `cbreal:latest` CPU Sandbox image supplies Bash, Python 3,
`runuser`, `/proc`, `ps`, `stat`, and the evaluated harness. Each sample copies
only its small JSON input and Python service into the root-only runtime bundle;
the runner installs the service at a normal executable path and copies the
selected input into `/work` for the user task. No network, model, dataset, or
credential is required. `SANDBOX_PROJECT`, image references, and GLM-5.2
credentials remain root-side runtime configuration.
