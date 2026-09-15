from __future__ import annotations

import json
import pathlib

from acme_core import platform_name
from acme_batch_sampler import build_retry_plan


root = pathlib.Path(__file__).resolve().parents[3]
report = root / ".depctl" / "reports" / "batch_sampler_smoke.json"
plan = build_retry_plan("registry-eval-batch", max_attempts=4)

assert platform_name() == "model-registry"
assert plan["client"] == "registry-eval-batch"
assert plan["version"] == "4.1.0"
assert plan["max_attempts"] == 4
assert plan["backoff"] == [0.1, 0.3, 0.9, 2.7]

report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps({"batch_sampler": "ok", "plan": plan}, indent=2) + "\n")
