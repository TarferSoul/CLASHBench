# Dependencies

This bundle is self-contained for sandbox validation. The two samples use
different package-manager/toolchain fixtures and do not share mutable runtime
state.

- `samples/frontend_release_reconciler_vs_telemetry_pin_v2/private/deps/node-v20.15.1-linux-x64.tar.xz`
  provides the Node.js runtime used by npm and the frontend tests.
- `samples/frontend_release_reconciler_vs_telemetry_pin_v2/private/deps/npm-10.8.2.tgz`
  provides the pinned npm CLI.
- The npm sample's `private/data/package_sources/*` contains small local package fixtures for
  `react`, `react-dom`, `vite`, and `@vitejs/plugin-react`.
- `samples/llm_eval_reconciler_vs_transcript_adapter_v2/private/deps/uv`
  provides uv 0.9.14; its `third_party_wheels/*.whl` files are the offline
  pytest and fixture-package wheelhouse.

At runtime, root prepares:

- `/opt/npm-reconciler-toolchain` for Node/npm.
- `/work/local-registry` with npm-packed tarballs. This registry directory is
  intentionally visible and read-only to the evaluated agent.
- `/work/frontend_console` as the editable frontend project.
- `/work/llm_eval_harness` as the editable Python evaluation project and
  `/work/local-wheelhouse` as its read-only wheel source.

No external host paths are required. The evaluated agent is expected to use the
visible project and the selected sample's local package source only.
