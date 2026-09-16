#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"household_travelers":4}
  if op=="grooming_list":return {"ok":True,"appointments":self.state["grooming"],"fees":self.state["fees"]}
  if op=="outings_list":return {"ok":True,"outings":self.fixture["outings"]}
  if op in {"grooming_cancel","grooming_reschedule"}:
   x=next((x for x in self.state["grooming"] if x["id"]==r["id"] and x["status"]=="confirmed"),None)
   if not x:return {"ok":False,"error":"grooming_not_found"}
   before=copy.deepcopy(x)
   if op=="grooming_cancel":x["status"]="cancelled";fee={"type":"same_day_cancel","target":x["id"],"amount":x["price"]*0.3};self.state["fees"].append(fee);action="grooming.cancel"
   else:
    slot=next((s for s in self.fixture["grooming_slots"] if s["id"]==r["slot_id"]),None)
    if not slot:return {"ok":False,"error":"slot_not_found"}
    x["start"],x["end"]=slot["start"],slot["end"];fee=None;action="grooming.reschedule"
   self.audit(uid,action,x["id"],before,x,r.get("reason",""),{"fee":fee});self.save();return {"ok":True,"appointment":x,"fee":fee}
  if op=="outing_book":
   trip=next((x for x in self.fixture["outings"] if x["id"]==r["outing_id"]),None)
   if not trip or r["travelers"]>trip["tickets_available"]:return {"ok":False,"error":"outing_unavailable"}
   t={"id":f"trip_{self.state['next_trip']:04d}","outing_id":trip["id"],"depart":trip["depart"],"return":trip["return"],"travelers":r["travelers"],"tickets":"issued","itinerary":"confirmed","status":"confirmed"};self.state["next_trip"]+=1;self.state["trips"].append(t);self.audit(uid,"outing.book",t["id"],None,t);self.save();return {"ok":True,"trip":t,"warning":"in-home appointments are not automatically reconciled"}
if __name__=="__main__":serve(ScenarioService)
