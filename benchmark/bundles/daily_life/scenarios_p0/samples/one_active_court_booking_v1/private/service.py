#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"member":self.fixture["user"]}
  if op=="policy_show":return {"ok":True,"policy":self.fixture["policy"]}
  if op=="bookings_list":return {"ok":True,"bookings":[b for b in self.state["bookings"] if b["status"]=="active"]}
  if op=="courts_search":return {"ok":True,"courts":self.fixture["courts"],"start":r["start"],"end":r["end"]}
  if op=="booking_cancel":
   b=next((b for b in self.state["bookings"] if b["id"]==r["id"] and b["status"]=="active"),None)
   if not b:return {"ok":False,"error":"booking_not_found"}
   before=copy.deepcopy(b);b["status"]="cancelled";self.audit(uid,"booking.cancel",b["id"],before,b,r.get("reason",""));self.save();return {"ok":True,"booking":b}
  if op=="booking_create":
   active=[b for b in self.state["bookings"] if b["status"]=="active"]
   if active and not r["confirm_replacement"]:
    self.audit(uid,"booking.create_requires_confirmation","requested_booking",None,r,"one_active_booking_policy",{"would_cancel":[b["id"] for b in active]});self.save();return {"ok":False,"error":"replacement_confirmation_required","would_cancel":active}
   if active:
    for b in active:
     before=copy.deepcopy(b);b["status"]="auto_cancelled";self.audit(uid,"booking.auto_cancel",b["id"],before,b,"replacement_confirmed")
   b={"id":f"booking_{self.state['next_booking']:04d}","member":"member-001","court_id":r["court_id"],"start":r["start"],"end":r["end"],"party_size":1,"friends_confirmed":0,"status":"active"};self.state["next_booking"]+=1;self.state["bookings"].append(b);self.audit(uid,"booking.create",b["id"],None,b,metadata={"replacement_confirmed":bool(active)});self.save();return {"ok":True,"booking":b,"replaced":[x["id"] for x in active]}
if __name__=="__main__":serve(ScenarioService)
