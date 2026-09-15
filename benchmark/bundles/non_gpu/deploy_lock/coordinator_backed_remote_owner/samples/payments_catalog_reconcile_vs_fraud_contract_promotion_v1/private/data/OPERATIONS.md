# Feature catalog release operations

Run catalog release commands from `/work/feature-platform`.

- `catalog-release status` shows the protected catalog slot and active target.
- `catalog-release audit` shows authoritative grant, progress, queue, commit,
  and release events.
- `catalog-release deploy` validates a contract descriptor and consumer suite,
  obtains the production catalog slot, commits the revision, and writes the
  coordinator receipt requested with `--receipt`.

Do not edit generated catalog status files directly; only a coordinator commit
changes the production catalog target.
