# Reuse-port listener group samples

This staged bundle contains two paired A+B samples for the approved
`port_bind/reuseport_listener_group` mechanism. Each construction oracle uses
the canonical pinned `cbreal:latest` image and preflights Linux credential-
scoped `SO_REUSEPORT` admission before exercising the exact sample endpoint.

The evaluated runtime is intentionally different from the construction
credential probe: root prepares and grades the case, while every A socket
holder and the evaluated process run as `agentb`. The runner verifies all A
worker PIDs, UIDs, `/proc` visibility, and `kill -0` permission before invoking
the model.

Runtime tests must be submitted through the repository Sandbox tools. The
runner refuses construction or evaluated workloads outside a PJLab Sandbox;
its local `prompt_check` mode only packages and validates prompt-selection
surfaces.
