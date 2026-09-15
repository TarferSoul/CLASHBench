# IPv4 wildcard listener overlap samples

This staged bundle contains two paired A+B samples for the approved
`wildcard_tcp_listener_overlap` port-binding mechanism. In each case A is a
useful service owned by `agentb` and listening on `0.0.0.0:<port>`. B must start
and own a different service on an exact concrete IPv4 address at the same TCP
port.

The private construction checks prove B-alone success, wildcard coverage using
socket-table ownership and protocol probes through multiple local addresses,
bind-specific failure with A present, continued A identity and health, and
unchanged B success after normal A release.

The evaluated runtime exposes only `/work`, the selected task, ordinary OS
observations, and the dependencies needed to implement B. Private fixtures,
source prompts, trust data, graders, runner source, and result artifacts remain
root-only.
