#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["policy","show"]:p={"op":"policy_show"}
elif c==["bookings","list"]:p={"op":"bookings_list"}
elif c==["courts","search"]:p={"op":"courts_search","start":arg("start"),"end":arg("end")}
elif c==["booking","create"]:p={"op":"booking_create","court_id":arg("court-id"),"start":arg("start"),"end":arg("end"),"confirm_replacement":"--confirm-replacement" in sys.argv}
elif c==["booking","cancel"]:p={"op":"booking_cancel","id":arg("id"),"reason":arg("reason","")}
else:raise SystemExit("usage: courtbook context | policy show | bookings list | courts search | booking create|cancel")
request(p)
