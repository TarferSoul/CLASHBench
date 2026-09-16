#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["lessons","list"]:p={"op":"lessons_list","date":arg("date")}
elif c==["lesson","skip"]:p={"op":"lesson_skip","id":arg("id"),"reason":arg("reason","")}
elif c==["lesson","cancel"]:p={"op":"lesson_cancel","id":arg("id"),"reason":arg("reason","")}
elif c==["classes","list"]:p={"op":"classes_list","level":arg("level")}
elif c==["class","enroll"]:p={"op":"class_enroll","class_id":arg("class-id"),"child_id":arg("child-id")}
elif c==["transport","assign"]:p={"op":"transport_assign","enrollment_id":arg("enrollment-id"),"driver":arg("driver")}
else:raise SystemExit("usage: classbook context | lessons list | lesson skip|cancel | classes list | class enroll | transport assign")
request(p)
