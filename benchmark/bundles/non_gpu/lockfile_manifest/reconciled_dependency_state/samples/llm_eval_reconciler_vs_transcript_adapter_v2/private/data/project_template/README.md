# LLM Evaluation Harness

This local harness validates provider adapter behavior from a pinned `uv.lock`.
The project is configured to resolve packages from `/work/local-wheelhouse`.

Common commands:

```bash
uv lock --offline --no-index --find-links /work/local-wheelhouse
uv sync --frozen --offline --no-index --find-links /work/local-wheelhouse --group dev
.venv/bin/python -m pytest tests/provider_compat/test_legacy_transcript_decoder.py -q
```

The image build reads only this directory's `pyproject.toml` and `uv.lock`.
