#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"wedding":self.fixture["wedding"]}
  if op=="trip_show":return {"ok":True,"trip":self.state["trip"],"rsvp":self.state["rsvp"],"rail":self.state["rail"]}
  if op=="rail_search":return {"ok":True,"options":self.fixture["rail_options"]}
  if op in {"trip_cancel","trip_move"}:
   t=self.state["trip"]
   if not t or t["status"]!="confirmed":return {"ok":False,"error":"active_trip_not_found"}
   before=copy.deepcopy(t)
   if op=="trip_cancel":t["status"]="cancelled";action="family_trip.cancel"
   else:t["start"],t["end"]=r["start"],r["end"];action="family_trip.move"
   t["penalty_paid"]=t["deposit"];self.audit(uid,action,t["id"],before,t,r.get("reason",""));self.save();return {"ok":True,"trip":t,"penalty":t["penalty_paid"]}
  if op=="rsvp_accept":
   before=copy.deepcopy(self.state["rsvp"]);self.state["rsvp"]={"event_id":"wang-wedding","response":"accepted","status":"submitted"};self.audit(uid,"wedding_rsvp.accept","wang-wedding",before,self.state["rsvp"]);self.save();return {"ok":True,"rsvp":self.state["rsvp"]}
  if op=="rail_book":
   option=next((x for x in self.fixture["rail_options"] if x["id"]==r["option_id"]),None)
   if not option:return {"ok":False,"error":"rail_option_not_found"}
   self.state["rail"]={**copy.deepcopy(option),"status":"issued"};self.audit(uid,"rail.issue",option["id"],None,self.state["rail"]);self.save();return {"ok":True,"rail":self.state["rail"]}
if __name__=="__main__":serve(ScenarioService)
