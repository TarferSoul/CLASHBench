#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["reservations","list"]:p={"op":"reservations_list"}
elif c==["reservation","delete"]:p={"op":"reservation_delete","id":arg("id"),"reason":arg("reason","")}
elif c==["reservation","shorten"]:p={"op":"reservation_shorten","id":arg("id"),"end":arg("end"),"reason":arg("reason","")}
elif c==["reservation","create"]:p={"op":"reservation_create","vehicle":arg("vehicle"),"start":arg("start"),"end":arg("end"),"target":int(arg("target"))}
else:raise SystemExit("usage: chargehome context | reservations list | reservation create|delete|shorten")
request(p)
