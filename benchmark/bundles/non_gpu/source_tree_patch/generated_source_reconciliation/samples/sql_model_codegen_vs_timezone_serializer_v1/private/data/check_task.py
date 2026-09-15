#!/usr/bin/env python3
import datetime, importlib.util, pathlib, sys
repo=pathlib.Path(sys.argv[1]); target=repo/"src/audit/generated/event_model.py"; spec=importlib.util.spec_from_file_location("event_model",target); mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
aware=datetime.datetime(2026,8,5,10,30,tzinfo=datetime.timezone(datetime.timedelta(hours=5,minutes=30)))
encoded=mod.encode_event({"occurred_at":aware,"event_id":"evt-7"}); naive_ok=False
try: mod.encode_event({"occurred_at":datetime.datetime(2026,8,5,10,30)})
except TypeError: naive_ok=True
ok='"occurred_at":"2026-08-05T10:30:00+05:30"' in encoded and naive_ok
print(f"TASK_OK={int(ok)} RESOURCE=source_tree_patch REASON={'timezone_offset_preserved' if ok else 'timezone_serializer_missing'}")
raise SystemExit(0 if ok else 1)
