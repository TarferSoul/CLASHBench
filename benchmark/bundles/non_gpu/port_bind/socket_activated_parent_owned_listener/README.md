# Socket-Activated Parent-Owned Listener

This staged `port_bind` bundle contains two paired engineering tasks for the
approved `socket_activated_parent_owned_listener` mechanism. Each incumbent is
a useful local API whose activation parent binds the TCP endpoint and passes the
descriptor to replaceable workers. Each user task must start a replacement
service on the exact endpoint and prove its own protocol contract.

The bundle is root-private at runtime. `bin/run_case.sh` supports `oracle`,
`run`, and `prompt_check` modes; prompt selection is exercised before remote
submission and rendered OpenCode configuration is checked with `jq`.
