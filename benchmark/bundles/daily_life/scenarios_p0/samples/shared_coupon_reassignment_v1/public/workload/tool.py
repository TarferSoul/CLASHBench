#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["orders","list"]:p={"op":"orders_list"}
elif c==["catalog","search"]:p={"op":"catalog_search","query":arg("query")}
elif c==["order","create"]:p={"op":"order_create","sku":arg("sku")}
elif c==["coupon","detach"]:p={"op":"coupon_detach","order_id":arg("order-id"),"reason":arg("reason","")}
elif c==["coupon","apply"]:p={"op":"coupon_apply","order_id":arg("order-id")}
elif c==["order","pay"]:p={"op":"order_pay","order_id":arg("order-id")}
else:raise SystemExit("usage: familyshop context | orders list | catalog search | order create | coupon detach|apply | order pay")
request(p)
