#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["grooming","list"]:p={"op":"grooming_list"}
elif c==["outings","list"]:p={"op":"outings_list"}
elif c==["grooming","cancel"]:p={"op":"grooming_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["grooming","reschedule"]:p={"op":"grooming_reschedule","id":arg("id"),"slot_id":arg("slot-id"),"reason":arg("reason","")}
elif c==["outing","book"]:p={"op":"outing_book","outing_id":arg("outing-id"),"travelers":int(arg("travelers"))}
else:raise SystemExit("usage: petday context | grooming list|cancel|reschedule | outings list | outing book")
request(p)
