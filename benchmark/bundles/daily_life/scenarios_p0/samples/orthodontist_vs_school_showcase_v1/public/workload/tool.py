#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["appointments","list"]:p={"op":"appointments_list"}
elif c==["school","event"]:p={"op":"school_event"}
elif c==["appointment","cancel"]:p={"op":"appointment_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["appointment","reschedule"]:p={"op":"appointment_reschedule","id":arg("id"),"reason":arg("reason","")}
elif c==["showcase","register"]:p={"op":"showcase_register"}
elif c==["receipt","submit"]:p={"op":"receipt_submit","registration_id":arg("registration-id")}
else:raise SystemExit("usage: familyhealth context | appointments list | school event | appointment cancel|reschedule | showcase register | receipt submit")
request(p)
