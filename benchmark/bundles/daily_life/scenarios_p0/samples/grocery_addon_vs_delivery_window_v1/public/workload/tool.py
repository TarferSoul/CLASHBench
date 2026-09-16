#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
def items():
 out=[]
 for i,x in enumerate(sys.argv):
  if x=="--item":out.append(sys.argv[i+1])
 return out
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["orders","list"]:p={"op":"orders_list"}
elif c==["order","show"]:p={"op":"order_show","id":arg("id")}
elif c==["inventory","check"]:p={"op":"inventory_check","item":arg("item"),"window":arg("window")}
elif c==["order","add"]:p={"op":"order_add","id":arg("id"),"items":items()}
elif c==["order","change-window"]:p={"op":"order_change_window","id":arg("id"),"window":arg("window"),"reason":arg("reason","")}
else:raise SystemExit("usage: freshcart context | orders list | order show|add|change-window | inventory check")
request(p)
