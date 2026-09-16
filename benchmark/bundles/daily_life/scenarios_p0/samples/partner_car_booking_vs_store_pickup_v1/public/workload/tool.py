#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):
    f="--"+n; return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]: p={"op":"context"}
elif c==["vehicle","schedule"]: p={"op":"vehicle_schedule","date":arg("date")}
elif c==["pickup","slots"]: p={"op":"pickup_slots","date":arg("date")}
elif c==["booking","cancel"]: p={"op":"booking_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["booking","move"]: p={"op":"booking_move","id":arg("id"),"start":arg("start"),"end":arg("end"),"reason":arg("reason","")}
elif c==["pickup","reserve"]: p={"op":"pickup_reserve","slot_id":arg("slot-id")}
elif c==["transport","plan"]: p={"op":"transport_plan","pickup_id":arg("pickup-id"),"mode":arg("mode"),"start":arg("start"),"end":arg("end")}
else: raise SystemExit("usage: familycar context | vehicle schedule | pickup slots|reserve | booking cancel|move | transport plan")
request(p)
