# Terraform State: Renewable Remote Backend Lease

This staged bundle contains one paired A+B sample for the approved
`terraform_state/renewable_remote_backend_lease` profile.

Sample:

- `feature_store_private_endpoint_consul_lease_v1`: A is a production
  feature-store networking apply that retains a renewable Consul-style backend
  session while gateway rollout checks continue. B applies a prepared private
  endpoint validation rule and must commit the same state key before writing its
  report.

The construction oracle proves that B can commit when A is absent, that A keeps
renewing one backend lease while provider work advances, that B cannot acquire
the same writer lease during A, and that B succeeds unchanged after A releases.

