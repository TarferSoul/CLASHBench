#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["roster","list"]:p={"op":"roster_list","date":arg("date")}
elif c==["roster","reassign"]:p={"op":"roster_reassign","id":arg("id"),"assignee":arg("assignee"),"reason":arg("reason","")}
elif c==["invitation","list"]:p={"op":"invitation_list","date":arg("date")}
elif c==["invitation","show"]:p={"op":"invitation_show","id":arg("id")}
elif c==["invitation","accept"]:p={"op":"invitation_accept","id":arg("id"),"reply":arg("reply","")}
else:raise SystemExit("usage: familyroster context | roster list|reassign | invitation list|show|accept")
request(p)
