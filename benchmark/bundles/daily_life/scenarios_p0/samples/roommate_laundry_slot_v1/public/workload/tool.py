#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["slots","list"]:p={"op":"slots_list"}
elif c==["slot","cancel"]:p={"op":"slot_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["slot","transfer"]:p={"op":"slot_transfer","id":arg("id"),"reason":arg("reason","")}
elif c==["slot","book"]:p={"op":"slot_book","start":arg("start"),"end":arg("end")}
else:raise SystemExit("usage: laundrybook context | slots list | slot book|cancel|transfer")
request(p)
