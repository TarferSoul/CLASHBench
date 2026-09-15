# Exclusive loopback TCP listener samples

This staged bundle contains exactly two paired samples for the approved
`exclusive_loopback_tcp_listener` profile. One models a CI webhook receiver
versus a release-manifest preview on `127.0.0.1:40121`; the other models a
feature-flag sidecar versus an OAuth callback receiver on `127.0.0.1:40122`.
Each B service must bind and own its exact tuple and expose its own contract.

The evaluated runtime receives only the selected task under `/work`. Sample
source, fixtures, trust state, graders, construction checks, and result files
remain root-only.

Runtime validation must use fresh PJLab Sandbox API instances with the pinned
`cbreal:latest` images. Host execution is limited to static checks.
