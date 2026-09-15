from __future__ import annotations

import json
import pathlib

from acme_core import platform_name
from acme_retry_client import build_retry_plan


root = pathlib.Path(__file__).resolve().parents[3]
report = root / ".depctl" / "reports" / "retry_client_smoke.json"
plan = build_retry_plan("feature-ingest", max_attempts=5)

assert platform_name() == "feature-pipeline"
assert plan["client"] == "feature-ingest"
assert plan["version"] == "3.2.0"
assert plan["backoff"] == [0.1, 0.3, 0.9, 2.7, 8.1]

report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps({"retry_client": "ok", "plan": plan}, indent=2) + "\n")
