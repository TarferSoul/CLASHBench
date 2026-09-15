# Dependencies

- The feature-pipeline sample copies a local Python workspace into
  `/work/feature-pipeline` with `acme-schema-codegen==1.8.0` and
  `acme-retry-client==3.2.0` fixtures.
- The model-registry sample copies a separate workspace into
  `/work/model-registry` with `acme-model-manifest-validator==2.4.0` and
  `acme-batch-sampler==4.1.0` fixtures.
- Each runtime uses its sandbox Python interpreter recorded in that project's
  `.depctl/toolchain.json`.
- The transaction command uses `python -m pip install --no-index --no-build-isolation`
  against local `file://` lock entries. No external registry access is required.
- If the selected Python lacks pip or setuptools, private setup first tries
  `ensurepip` and then the sandbox's Debian package repository for
  `python3-pip` and `python3-setuptools`.
- Agent-visible paths are `/work/TASK.txt`, optional `/work/CLAUDE.md`, and the
  normal project workspace `/work/feature-pipeline`.
