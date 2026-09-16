#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["shifts","list"]:p={"op":"shifts_list"}
elif c==["therapy","slots"]:p={"op":"therapy_slots"}
elif c==["shift","cancel"]:p={"op":"shift_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["shift","shorten"]:p={"op":"shift_shorten","id":arg("id"),"end":arg("end"),"reason":arg("reason","")}
elif c==["therapy","book"]:p={"op":"therapy_book","slot_id":arg("slot-id")}
elif c==["ride","book"]:p={"op":"ride_book","appointment_id":arg("appointment-id")}
else:raise SystemExit("usage: careplan context | shifts list | therapy slots|book | shift cancel|shorten | ride book")
request(p)
