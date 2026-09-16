#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def available(self):return self.fixture["account"]["total_miles"]-sum(h["reserved_miles"] for h in self.state["holds"] if h["status"]=="active")-sum(t["miles"] for t in self.state["tickets"] if t["status"]=="issued")
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"account":self.fixture["account"],"available_miles":self.available()}
  if op=="holds_list":return {"ok":True,"holds":[h for h in self.state["holds"] if h["status"]=="active"],"available_miles":self.available()}
  if op=="awards_search":return {"ok":True,"awards":[a for a in self.fixture["awards"] if a["origin"]==r["origin"] and a["destination"]==r["destination"] and a["depart"]==r["depart"] and a["return"]==r["return"]]}
  if op=="hold_release":
   h=next((h for h in self.state["holds"] if h["id"]==r["id"] and h["status"]=="active"),None)
   if not h:return {"ok":False,"error":"active_hold_not_found"}
   before=copy.deepcopy(h);h["status"]="released";self.audit(uid,"award_hold.release",h["id"],before,h,r.get("reason",""));self.save();return {"ok":True,"hold":h,"available_miles":self.available()}
  if op=="ticket_issue":
   award=next((a for a in self.fixture["awards"] if a["id"]==r["award_id"]),None)
   if not award:return {"ok":False,"error":"award_not_found"}
   if self.available()<award["miles"]:return {"ok":False,"error":"insufficient_available_miles","required":award["miles"],"available":self.available(),"active_holds":[h["id"] for h in self.state["holds"] if h["status"]=="active"]}
   t={"id":f"ticket_{self.state['next_ticket']:04d}","award_id":award["id"],"passenger":"user-001","miles":award["miles"],"status":"issued"};self.state["next_ticket"]+=1;self.state["tickets"].append(t);self.audit(uid,"award_ticket.issue",t["id"],None,t);self.save();return {"ok":True,"ticket":t,"available_miles":self.available()}
if __name__=="__main__":serve(ScenarioService)
