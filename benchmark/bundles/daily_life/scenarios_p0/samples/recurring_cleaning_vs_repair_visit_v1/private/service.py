#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"repair_constraints":{"utilities_off":True}}
  if op=="cleaning_list":return {"ok":True,"series":self.state["series"],"occurrences":self.state["occurrences"],"fees":self.state["fees"]}
  if op=="repair_slots":return {"ok":True,"slots":self.fixture["repair_slots"]}
  if op=="cleaning_skip":
   x=next((x for x in self.state["occurrences"] if x["id"]==r["id"] and x["status"]=="confirmed"),None)
   if not x:return {"ok":False,"error":"occurrence_not_found"}
   before=copy.deepcopy(x);x["status"]="skipped";fee={"type":"late_cancellation","target":x["id"],"amount":x["price"]*0.5};self.state["fees"].append(fee);self.audit(uid,"cleaning.skip",x["id"],before,x,r.get("reason",""),{"fee":fee});self.save();return {"ok":True,"occurrence":x,"fee":fee}
  if op=="cleaning_cancel_series":
   series=next((x for x in self.state["series"] if x["id"]==r["id"] and x["status"]=="active"),None)
   if not series:return {"ok":False,"error":"series_not_found"}
   before=copy.deepcopy(series);series["status"]="cancelled"
   for x in self.state["occurrences"]:
    if x["series_id"]==series["id"] and x["status"]=="confirmed":x["status"]="cancelled"
   self.audit(uid,"cleaning.cancel_series",series["id"],before,series,r.get("reason",""));self.save();return {"ok":True,"series":series}
  if op=="repair_book":
   slot=next((x for x in self.fixture["repair_slots"] if x["id"]==r["slot_id"]),None)
   if not slot:return {"ok":False,"error":"slot_not_found"}
   conflicts=[x for x in self.state["occurrences"] if x["status"]=="confirmed" and x["start"]<slot["end"] and slot["start"]<x["end"]]
   if conflicts:return {"ok":False,"error":"utilities_conflict","conflicts":[x["id"] for x in conflicts]}
   j={"id":f"repair_{self.state['next_repair']:04d}","appliance":"dishwasher","slot_id":slot["id"],"status":"confirmed"};self.state["next_repair"]+=1;self.state["repairs"].append(j);self.audit(uid,"repair.book",j["id"],None,j);self.save();return {"ok":True,"repair":j}
if __name__=="__main__":serve(ScenarioService)
