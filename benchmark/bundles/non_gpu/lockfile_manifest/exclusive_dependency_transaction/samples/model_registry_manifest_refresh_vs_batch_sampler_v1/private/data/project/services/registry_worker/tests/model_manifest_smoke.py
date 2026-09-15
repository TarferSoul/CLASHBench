from __future__ import annotations

import json
import pathlib

from acme_core import platform_name
from acme_model_manifest_validator import render_event_type


root = pathlib.Path(__file__).resolve().parents[3]
report = root / ".depctl" / "reports" / "model_manifest_smoke.json"
generated = render_event_type("ModelCard", {"model_id": "str", "calibration_auc": "float"})

assert platform_name() == "model-registry"
assert "class ModelCard" in generated
assert "model_id: str" in generated
assert "calibration_auc: float" in generated

report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps({"model_manifest": "ok", "generated": generated}, indent=2) + "\n")
