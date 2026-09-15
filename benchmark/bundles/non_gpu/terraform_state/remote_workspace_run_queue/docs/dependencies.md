# Dependencies

Each sample is self-contained and uses Python 3 standard-library HTTP and JSON
support plus standard Linux tools (`bash`, `runuser`, `ps`, `stat`, and
`sha256sum`). No network service, cloud credential, Terraform credential,
package download, host mount, or external dataset is required.

The private setup installs a sample-local remote workspace client as
`/usr/local/bin/tfremote` and exposes its non-secret context at
`/etc/remoteiac/context.json`. The selected B change specification is copied to
the sample-specific project below `/work`. Those are intentionally
agent-visible. Control-plane state and all grading evidence remain root-only.
