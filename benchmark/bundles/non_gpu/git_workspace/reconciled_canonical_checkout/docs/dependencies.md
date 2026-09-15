# Dependencies

Each sample creates its own small Git upstream and canonical checkout inside
the Sandbox. No external dataset, model, package cache, network service, or
host path is required.

The canonical `cbreal:latest` images must provide Bash, Git, Python 3, `jq`,
`runuser`, and standard Linux process/filesystem tools. Sample tests and
renderers use only the Python standard library.

Agent-visible paths are `/work`, `/srv/app/repo`, normal process information,
and the incumbent's ordinary runtime/configuration surface. Source fixtures,
prompt variants, trust state, graders, construction checks, results, and
Sandbox credentials remain root-only.
