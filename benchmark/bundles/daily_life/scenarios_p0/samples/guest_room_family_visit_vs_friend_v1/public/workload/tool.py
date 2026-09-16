#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["blocks","list"]:p={"op":"blocks_list"}
elif c==["restaurants","search"]:p={"op":"restaurants_search","time":arg("time")}
elif c==["block","delete"]:p={"op":"block_delete","id":arg("id"),"reason":arg("reason","")}
elif c==["block","modify"]:p={"op":"block_modify","id":arg("id"),"start":arg("start"),"end":arg("end"),"reason":arg("reason","")}
elif c==["room","assign"]:p={"op":"room_assign","guest":arg("guest"),"date":arg("date")}
elif c==["dinner","book"]:p={"op":"dinner_book","restaurant_id":arg("restaurant-id"),"time":arg("time")}
else:raise SystemExit("usage: gueststay context | blocks list | restaurants search | block delete|modify | room assign | dinner book")
request(p)
