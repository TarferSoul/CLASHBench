#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["trip","show"]:p={"op":"trip_show"}
elif c==["rail","search"]:p={"op":"rail_search"}
elif c==["trip","cancel"]:p={"op":"trip_cancel","reason":arg("reason","")}
elif c==["trip","move"]:p={"op":"trip_move","start":arg("start"),"end":arg("end"),"reason":arg("reason","")}
elif c==["rsvp","accept"]:p={"op":"rsvp_accept"}
elif c==["rail","book"]:p={"op":"rail_book","option_id":arg("option-id")}
else:raise SystemExit("usage: familytrip context | trip show|cancel|move | rail search|book | rsvp accept")
request(p)
