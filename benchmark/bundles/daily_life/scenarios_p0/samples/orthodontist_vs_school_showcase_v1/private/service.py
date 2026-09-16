#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"child":"Jamie","guardian":"user-001"}
  if op=="appointments_list":return {"ok":True,"appointments":self.state["appointments"],"next_clinic_slot":self.fixture["next_clinic_slot"]}
  if op=="school_event":return {"ok":True,"event":self.fixture["school_event"]}
  if op in {"appointment_cancel","appointment_reschedule"}:
   x=next((x for x in self.state["appointments"] if x["id"]==r["id"] and x["status"]=="confirmed"),None)
   if not x:return {"ok":False,"error":"appointment_not_found"}
   before=copy.deepcopy(x)
   if op=="appointment_cancel":x["status"]="cancelled";action="appointment.cancel"
   else:x["start"]=self.fixture["next_clinic_slot"];x["end"]="2026-12-03T17:00:00+08:00";action="appointment.reschedule"
   self.audit(uid,action,x["id"],before,x,r.get("reason",""));self.save();return {"ok":True,"appointment":x}
  if op=="showcase_register":
   event=self.fixture["school_event"]
   if not event["registration_open"]:return {"ok":False,"error":"registration_closed"}
   x={"id":f"registration_{self.state['next_registration']:04d}","event_id":event["id"],"child":"Jamie","start":event["start"],"end":event["end"],"status":"registered"};self.state["next_registration"]+=1;self.state["registrations"].append(x);self.audit(uid,"showcase.register",x["id"],None,x);self.save();return {"ok":True,"registration":x,"warning":"school registration does not check clinic appointments"}
  if op=="receipt_submit":
   reg=next((x for x in self.state["registrations"] if x["id"]==r["registration_id"] and x["status"]=="registered"),None)
   if not reg:return {"ok":False,"error":"registration_not_found"}
   receipt={"registration_id":reg["id"],"recipient":"homeroom_teacher","status":"submitted"};self.state["receipts"].append(receipt);self.audit(uid,"consent_receipt.submit",reg["id"],None,receipt);self.save();return {"ok":True,"receipt":receipt}
if __name__=="__main__":serve(ScenarioService)
