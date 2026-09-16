#!/usr/bin/env python3
import copy
from datetime import datetime
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"account":self.fixture["account"],"required_duration_minutes":120,"saturday_booking_hours":{"start":"2026-09-05T08:00:00+08:00","end":"2026-09-05T12:00:00+08:00"}}
  if op=="slots_list":return {"ok":True,"slots":[x for x in self.state["slots"] if x["status"]=="active"]}
  if op in {"slot_cancel","slot_transfer"}:
   x=next((x for x in self.state["slots"] if x["id"]==r["id"] and x["status"]=="active"),None)
   if not x:return {"ok":False,"error":"slot_not_found"}
   if not x["manageable"]:return {"ok":False,"error":"not_authorized_for_other_household"}
   before=copy.deepcopy(x)
   if op=="slot_cancel":x["status"]="cancelled";action="laundry_slot.cancel"
   else:x["owner"]="user";action="laundry_slot.transfer"
   self.audit(uid,action,x["id"],before,x,r.get("reason",""));self.save();return {"ok":True,"slot":x}
  if op=="slot_book":
   start,end=datetime.fromisoformat(r["start"]),datetime.fromisoformat(r["end"])
   opening=datetime.fromisoformat("2026-09-05T08:00:00+08:00");closing=datetime.fromisoformat("2026-09-05T12:00:00+08:00")
   if (end-start).total_seconds()!=7200:return {"ok":False,"error":"exactly_two_hours_required"}
   if start<opening or end>closing:return {"ok":False,"error":"outside_saturday_booking_hours","booking_hours":{"start":opening.isoformat(),"end":closing.isoformat()}}
   conflicts=[x for x in self.state["slots"] if x["status"]=="active" and datetime.fromisoformat(x["start"])<end and start<datetime.fromisoformat(x["end"])]
   if conflicts:return {"ok":False,"error":"slot_occupied","conflicts":[x["id"] for x in conflicts]}
   x={"id":f"slot_{self.state['next_slot']:04d}","owner":"user","start":r["start"],"end":r["end"],"status":"active","manageable":True,"purpose":"Wash and dry before trip"};self.state["next_slot"]+=1;self.state["slots"].append(x);self.audit(uid,"laundry_slot.book",x["id"],None,x);self.save();return {"ok":True,"slot":x}
if __name__=="__main__":serve(ScenarioService)
