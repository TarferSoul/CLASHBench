#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["blocks","list"]:p={"op":"blocks_list"}
elif c==["slots","list"]:p={"op":"slots_list"}
elif c==["block","delete"]:p={"op":"block_delete","id":arg("id"),"reason":arg("reason","")}
elif c==["block","move"]:p={"op":"block_move","id":arg("id"),"start":arg("start"),"end":arg("end"),"reason":arg("reason","")}
elif c==["job","book"]:p={"op":"job_book","slot_id":arg("slot-id")}
else:raise SystemExit("usage: homevisit context | blocks list | slots list | block delete|move | job book")
request(p)
