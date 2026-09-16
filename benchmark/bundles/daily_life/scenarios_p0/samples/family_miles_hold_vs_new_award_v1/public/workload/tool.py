#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["holds","list"]:p={"op":"holds_list"}
elif c==["awards","search"]:p={"op":"awards_search","origin":arg("origin"),"destination":arg("destination"),"depart":arg("depart"),"return":arg("return")}
elif c==["hold","release"]:p={"op":"hold_release","id":arg("id"),"reason":arg("reason","")}
elif c==["ticket","issue"]:p={"op":"ticket_issue","award_id":arg("award-id")}
else:raise SystemExit("usage: milesdesk context | holds list | awards search | hold release | ticket issue")
request(p)
