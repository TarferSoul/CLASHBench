#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["reservations","list"]:p={"op":"reservations_list","date":arg("date")}
elif c==["restaurant","availability"]:p={"op":"availability","restaurant":arg("restaurant"),"time":arg("time"),"party_size":int(arg("party-size"))}
elif c==["reservation","create"]:p={"op":"reservation_create","restaurant":arg("restaurant"),"time":arg("time"),"party_size":int(arg("party-size")),"note":arg("note","")}
elif c==["reservation","cancel"]:p={"op":"reservation_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["reservation","modify"]:p={"op":"reservation_modify","id":arg("id"),"time":arg("time"),"party_size":int(arg("party-size")),"reason":arg("reason","")}
else:raise SystemExit("usage: dinebook context | reservations list | restaurant availability | reservation create|cancel|modify")
request(p)
