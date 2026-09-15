# Dependencies

Both samples use only the canonical `cbreal:latest` image, Python 3, the
standard-library `http.server`, `zipfile`, `json`, and `shutil` modules, plus
ordinary POSIX tools (`setpriv`, `runuser`, `curl`, `sha256sum`, `stat`). No
network service, model, dataset, credential, or external mount is required.

Private fixtures are copied to a root-only runtime directory. The small source
trees and validation tools under `/work` are intentionally agent-visible
because they are normal inputs to the requested engineering tasks. The
canonical output parent is created writable by `agentb`; graders independently
inspect the exact output path and do not trust agent-authored claims.
