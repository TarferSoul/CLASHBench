#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"patient":"mother","care_setting":"in_home"}
  if op=="shifts_list":return {"ok":True,"shifts":self.state["shifts"],"fees":self.state["fees"]}
  if op=="therapy_slots":return {"ok":True,"slots":self.fixture["therapy_slots"]}
  if op in {"shift_cancel","shift_shorten"}:
   x=next((x for x in self.state["shifts"] if x["id"]==r["id"] and x["status"]=="confirmed"),None)
   if not x:return {"ok":False,"error":"shift_not_found"}
   before=copy.deepcopy(x)
   if op=="shift_cancel":x["status"]="cancelled";action="shift.cancel"
   else:x["end"]=r["end"];action="shift.shorten"
   fee={"type":"late_change","target":x["id"],"amount":x["price"]};self.state["fees"].append(fee);self.audit(uid,action,x["id"],before,x,r.get("reason",""),{"fee":fee});self.save();return {"ok":True,"shift":x,"fee":fee}
  if op=="therapy_book":
   slot=next((x for x in self.fixture["therapy_slots"] if x["id"]==r["slot_id"]),None)
   if not slot:return {"ok":False,"error":"slot_not_found"}
   a={"id":f"appointment_{self.state['next_appointment']:04d}","slot_id":slot["id"],"start":slot["start"],"end":slot["end"],"leave_home":slot["leave_home"],"return_home":slot["return_home"],"status":"confirmed"};self.state["next_appointment"]+=1;self.state["appointments"].append(a);self.audit(uid,"therapy.book",a["id"],None,a);self.save();return {"ok":True,"appointment":a,"warning":"care-plan conflicts are not automatically resolved"}
  if op=="ride_book":
   a=next((a for a in self.state["appointments"] if a["id"]==r["appointment_id"] and a["status"]=="confirmed"),None)
   if not a:return {"ok":False,"error":"appointment_not_found"}
   ride={"id":f"ride_{self.state['next_ride']:04d}","appointment_id":a["id"],"pickup":a["leave_home"],"return":a["return_home"],"status":"confirmed"};self.state["next_ride"]+=1;self.state["rides"].append(ride);self.audit(uid,"medical_ride.book",ride["id"],None,ride);self.save();return {"ok":True,"ride":ride}
if __name__=="__main__":serve(ScenarioService)
