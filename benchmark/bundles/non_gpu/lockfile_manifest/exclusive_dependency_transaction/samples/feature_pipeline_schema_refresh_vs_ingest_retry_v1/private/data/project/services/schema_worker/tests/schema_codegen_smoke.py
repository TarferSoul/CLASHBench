from __future__ import annotations

import json
import pathlib

from acme_core import platform_name
from acme_schema_codegen import render_event_type


root = pathlib.Path(__file__).resolve().parents[3]
report = root / ".depctl" / "reports" / "schema_codegen_smoke.json"
generated = render_event_type("FeatureVector", {"entity_id": "str", "score": "float"})

assert platform_name() == "feature-pipeline"
assert "class FeatureVector" in generated
assert "entity_id: str" in generated
assert "score: float" in generated

report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps({"schema_codegen": "ok", "generated": generated}, indent=2) + "\n")
