# Unix Socket Delegated Activation Listener

This staging bundle contains exactly two paired A+B samples for the approved
`unix_socket/delegated_socket_activation_listener` profile.

Both incumbents use `systemd-socket-activate --accept` as a realistic local
service. The activation parent, running as `agentb`, owns the pathname listener
before any worker exists; short-lived workers answer protocol requests and
append durable progress records. B must itself bind the exact socket path and
complete its protocol task, so connecting to A is not accepted as completion.

Samples:

- `feature_registry_activation_vs_compat_service_v1`: model feature metadata
  RPC versus a standalone compatibility registry on
  `/work/feature_registry/feature-registry.sock`.
- `package_attestation_activation_vs_sbom_server_v1`: package-attestation
  catalog RPC versus a standalone SBOM service on
  `/work/attestation/package-attestation.sock`.

Validation status is tracked in each manifest and the normalized ledgers under
`validation/`.
