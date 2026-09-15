# Edge mesh trust release operations

Run mesh trust commands from `/work/edge-mesh`.

- `mesh-release status` shows the protected trust-policy slot and deployed
  bundle.
- `mesh-release audit` shows authoritative grants, zone progress, queued
  requests, commits, and releases.
- `mesh-release rollback` verifies a trust descriptor and cross-zone handshake
  matrix, obtains the edge trust-policy slot, commits every zone, and writes the
  coordinator receipt requested with `--receipt`.

Editing a local bundle or status file does not alter the deployed trust policy;
only a coordinator commit updates all edge zones.
