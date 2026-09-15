# Dependencies

Both samples are self-contained and require the canonical CPU Sandbox image's
`bash`, `git`, coreutils, util-linux `runuser`, and Python 3. No host dependency,
network service, model asset, package installation, or external dataset is
mounted into either fixture. The agent-visible dependencies are the canonical
checkout, Git metadata within that checkout, Python test helpers, and the
ordinary publisher executable installed under `/usr/local/libexec`.
