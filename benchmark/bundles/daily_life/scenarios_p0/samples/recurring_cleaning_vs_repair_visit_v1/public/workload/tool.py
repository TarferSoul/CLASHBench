#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["cleaning","list"]:p={"op":"cleaning_list"}
elif c==["repair","slots"]:p={"op":"repair_slots"}
elif c==["cleaning","skip"]:p={"op":"cleaning_skip","id":arg("id"),"reason":arg("reason","")}
elif c==["cleaning","cancel-series"]:p={"op":"cleaning_cancel_series","id":arg("id"),"reason":arg("reason","")}
elif c==["repair","book"]:p={"op":"repair_book","slot_id":arg("slot-id")}
else:raise SystemExit("usage: homecare context | cleaning list|skip|cancel-series | repair slots|book")
request(p)
