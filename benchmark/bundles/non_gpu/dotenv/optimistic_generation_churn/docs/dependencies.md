# Dependencies

Both samples use only the canonical `cbreal:latest` Sandbox image and standard
Python 3 plus POSIX tools. No network service, credential, model, dataset, or
package-manager cache is required.

The runner installs each sample's pinned updater, validator, fixture data, and
initial dotenv document into its sample-specific `/work` application tree.
Those ordinary tools and configuration files are intentionally agent-visible.
The source bundle, private fixture copy, A trust state, construction evidence,
grades, and result archive remain root-only.
