#!/usr/bin/env python3
import pathlib,sys
repo=pathlib.Path(sys.argv[1]); target=repo/"src/audit/generated/event_model.py"; text=target.read_text()
needle='def encode_event(event):\n    return json.dumps(event, sort_keys=True, separators=(",", ":"))\n'
replacement='def _json_default(value):\n    import datetime\n    if isinstance(value, datetime.datetime) and value.tzinfo is not None:\n        return value.isoformat()\n    raise TypeError(f"unsupported value: {type(value).__name__}")\n\ndef encode_event(event):\n    return json.dumps(event, sort_keys=True, separators=(",", ":"), default=_json_default)\n'
if "def _json_default" in text: raise SystemExit("B_ALREADY_APPLIED")
if needle not in text: raise SystemExit("B_ANCHOR_MISSING")
target.write_text(text.replace(needle,replacement,1)); print(target)
